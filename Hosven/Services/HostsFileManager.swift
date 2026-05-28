import Foundation
import SwiftUI

struct HostEntry: Identifiable, Equatable {
    let id: UUID
    var ip: String
    var hostname: String
    var comment: String
    var isEnabled: Bool
    var isComment: Bool // pure comment line, not a disabled entry
    var tag: String? // nil = untagged

    init(id: UUID = UUID(), ip: String = "", hostname: String = "", comment: String = "", isEnabled: Bool = true, isComment: Bool = false, tag: String? = nil) {
        self.id = id
        self.ip = ip
        self.hostname = hostname
        self.comment = comment
        self.isEnabled = isEnabled
        self.isComment = isComment
        self.tag = tag
    }
}

struct HostTag: Identifiable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case enabled = "Đang bật"
    case disabled = "Đã tắt"
    case blocking = "Đang chặn"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "xmark.circle"
        case .blocking: return "hand.raised.fill"
        }
    }
}

enum ToastType {
    case success, error, info
}

struct ToastMessage: Equatable {
    let message: String
    let type: ToastType

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool {
        lhs.message == rhs.message
    }
}

@Observable
@MainActor
final class HostsFileManager {
    var entries: [HostEntry] = []
    var tags: [HostTag] = []
    var commentLines: [(index: Int, text: String)] = []
    var isApplying = false

    /// Serialized snapshot of the last clean state (load + post-apply). Compared
    /// against `generateHostsContent()` to derive `hasUnsavedChanges` — so undo
    /// back to the load state, or mutate-then-revert, both clear dirty automatically.
    private var pristineSerialized: String = ""

    /// Raw-text editor doesn't sync `entries` until apply. While the user types in
    /// raw mode we can't compare-by-value, so the view sets this flag to force
    /// dirty until the next apply/load.
    private var rawTextDirtyOverride = false

    /// `true` when the in-memory state differs from the last-saved disk content.
    /// Computed from `pristineSerialized` + `rawTextDirtyOverride` — never set
    /// directly. Use `captureClean()` to mark the current state as the new pristine.
    var hasUnsavedChanges: Bool {
        rawTextDirtyOverride || generateHostsContent() != pristineSerialized
    }
    var isSearchFocused = false
    /// Pending query pushed from the ⌘K palette. HostsView observes, applies to its
    /// own search field, then clears. Decouples palette from view-local @State.
    var pendingSearchQuery: String?
    var toast: ToastMessage?

    /// Profile metadata (color, shortcut) layered on top of tag-name markers in `/etc/hosts`.
    /// Synced with `tags` after every parse: new tags → unstyled profile (default color),
    /// orphan profiles preserved so user metadata survives temporary tag removal.
    var profiles: [Profile] = []

    /// `nil` means "show all" (legacy v1 behaviour). Non-nil = filter UI to this profile's tag.
    var activeProfileID: UUID?

    private var originalContent = ""
    private let hostsPath = "/etc/hosts"
    private let profileStore: ProfileStoring

    // MARK: - External change detection

    /// `true` when an external tool (Docker, terminal sudo write, etc.) modified
    /// `/etc/hosts` while we were running. UI shows amber warning + Reload action.
    /// Cleared after `loadHostsFile()` or user dismissal.
    var externalChangeDetected = false

    private let fileWatcher = HostsFileWatcher()

    // MARK: - Undo / Redo

    /// Snapshot stacks for undo/redo. Each snapshot captures `entries` only — tags and
    /// comments derive from entries on serialization, profile metadata is independent.
    /// Cap stack size to bound memory for very large hosts files.
    private var undoStack: [[HostEntry]] = []
    private var redoStack: [[HostEntry]] = []
    private static let maxUndoDepth = 50

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Push current `entries` onto the undo stack and clear the redo stack. Call BEFORE
    /// any mutation that should be undoable. Coalesces no-op pushes (same as last snapshot).
    private func pushUndo() {
        if let last = undoStack.last, last == entries { return }
        undoStack.append(entries)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
    }

    /// Restore previous snapshot. No-op if undo stack is empty.
    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(entries)
        entries = snapshot
    }

    /// Re-apply a previously undone change. No-op if redo stack is empty.
    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(entries)
        entries = snapshot
    }

    private func clearUndoStacks() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    init(profileStore: ProfileStoring = ProfileStore(), autoLoad: Bool = true) {
        self.profileStore = profileStore
        self.profiles = profileStore.load()
        if autoLoad {
            loadHostsFile()
            startWatchingHostsFile()
        } else {
            captureClean()
        }
    }

    /// Mark the current in-memory state as the new pristine baseline. Called after
    /// a successful load/apply, and exposed so tests can seed entries directly and
    /// then declare "this is now clean".
    func captureClean() {
        pristineSerialized = generateHostsContent()
        rawTextDirtyOverride = false
    }

    /// Force dirty even when entries match pristine. Used by the raw-text editor
    /// where pending changes live in view-local @State and don't reach `entries`
    /// until apply.
    func markRawTextDirty() {
        rawTextDirtyOverride = true
    }

    private func startWatchingHostsFile() {
        fileWatcher.onChange = { [weak self] event in
            guard let self else { return }
            // Suspend/resume on DispatchSourceFileSystemObject doesn't drop pending events
            // (they accumulate and fire on resume), so we also compare disk content against
            // what we last wrote — if it matches, this is our own write, not an external one.
            switch event {
            case .modified:
                if let onDisk = try? String(contentsOfFile: self.hostsPath, encoding: .utf8),
                   onDisk == self.originalContent {
                    return
                }
                self.externalChangeDetected = true
            case .deleted:
                self.externalChangeDetected = true
            }
        }
        fileWatcher.start()
    }

    func loadHostsFile() {
        do {
            let content = try String(contentsOfFile: hostsPath, encoding: .utf8)
            originalContent = content
            parseHostsContent(content)
            captureClean()
            externalChangeDetected = false
            clearUndoStacks()
        } catch {
            showToast("Không thể đọc file /etc/hosts: \(error.localizedDescription)", type: .error)
        }
    }

    private static let tagStartPattern = try! NSRegularExpression(pattern: #"^##\s*\[tag:(.+)\]\s*$"#)
    private static let tagEndPattern = try! NSRegularExpression(pattern: #"^##\s*\[/tag:(.+)\]\s*$"#)

    private func parseTagMarker(_ line: String) -> (isStart: Bool, name: String)? {
        let range = NSRange(line.startIndex..., in: line)
        if let match = Self.tagStartPattern.firstMatch(in: line, range: range),
           let nameRange = Range(match.range(at: 1), in: line) {
            return (isStart: true, name: String(line[nameRange]).trimmingCharacters(in: .whitespaces))
        }
        if let match = Self.tagEndPattern.firstMatch(in: line, range: range),
           let nameRange = Range(match.range(at: 1), in: line) {
            return (isStart: false, name: String(line[nameRange]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func parseHostsContent(_ content: String) {
        var newEntries: [HostEntry] = []
        var newCommentLines: [(index: Int, text: String)] = []
        var discoveredTagNames: [String] = []
        var currentTag: String? = nil
        let lines = content.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Check for tag markers
            if let marker = parseTagMarker(trimmed) {
                if marker.isStart {
                    currentTag = marker.name
                    if !discoveredTagNames.contains(where: { $0.lowercased() == marker.name.lowercased() }) {
                        discoveredTagNames.append(marker.name)
                    }
                } else {
                    currentTag = nil
                }
                continue // tag markers are metadata, not stored as comments
            }

            if trimmed.hasPrefix("#") {
                let uncommented = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                let parts = uncommented.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 && isValidIP(parts[0]) {
                    // Disabled entry
                    let comment = parts.count > 2 ? parts[2...].joined(separator: " ") : ""
                    let entry = HostEntry(
                        ip: parts[0],
                        hostname: parts[1],
                        comment: comment,
                        isEnabled: false,
                        isComment: false,
                        tag: currentTag
                    )
                    newEntries.append(entry)
                } else {
                    // Pure comment
                    newCommentLines.append((index: index, text: line))
                }
            } else {
                // Active entry
                let withoutComment: String
                let inlineComment: String
                if let hashIndex = trimmed.firstIndex(of: "#") {
                    withoutComment = String(trimmed[trimmed.startIndex..<hashIndex]).trimmingCharacters(in: .whitespaces)
                    inlineComment = String(trimmed[trimmed.index(after: hashIndex)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    withoutComment = trimmed
                    inlineComment = ""
                }

                let parts = withoutComment.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let entry = HostEntry(
                        ip: parts[0],
                        hostname: parts[1],
                        comment: inlineComment,
                        isEnabled: true,
                        isComment: false,
                        tag: currentTag
                    )
                    newEntries.append(entry)
                }
            }
        }

        entries = newEntries
        commentLines = newCommentLines
        tags = discoveredTagNames.map { HostTag(name: $0) }
        syncProfilesWithTags()
    }

    // MARK: - Profile sync

    /// Reconcile `profiles` with `tags`:
    /// - For each tag without a matching profile: create one with a guessed-from-name color.
    /// - Orphan profiles (no current tag) are preserved — metadata survives tag removal.
    /// Persists via `profileStore` after change.
    private func syncProfilesWithTags() {
        var changed = false
        for tag in tags where !profiles.contains(where: { $0.name == tag.name }) {
            let nextShortcut = (profiles.compactMap(\.shortcutNumber).max() ?? 0) + 1
            profiles.append(Profile(
                name: tag.name,
                color: Self.guessColor(for: tag.name, existing: profiles),
                shortcutNumber: nextShortcut <= 9 ? nextShortcut : nil
            ))
            changed = true
        }
        if changed {
            profileStore.save(profiles)
        }
    }

    /// Heuristic color picker. Honors common semantic names (release/production/master),
    /// otherwise rotates through the palette based on existing profile count.
    private static func guessColor(for name: String, existing: [Profile]) -> ProfileColor {
        let key = name.lowercased()
        if key.contains("release") { return .purple }
        if key.contains("prod")    { return .green }
        if key.contains("master")  { return .amber }
        if key.contains("dev") || key.contains("local") { return .blue }
        if key.contains("test") || key.contains("staging") { return .red }
        let palette = ProfileColor.allCases
        return palette[existing.count % palette.count]
    }

    // MARK: - Profile CRUD

    /// Switch active profile (or pass `nil` to show all). Does not modify hosts file.
    func switchProfile(to id: UUID?) {
        activeProfileID = id
    }

    /// Add a new profile with auto-assigned shortcut. Does not create a tag in hosts file
    /// (that happens when entries are tagged).
    func addProfile(name: String, color: ProfileColor) -> Profile? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let candidate = Profile(name: trimmed, color: color)
        guard candidate.isNameValid,
              !profiles.contains(where: { $0.name.lowercased() == trimmed.lowercased() })
        else { return nil }
        var profile = candidate
        profile.shortcutNumber = (profiles.compactMap(\.shortcutNumber).max() ?? 0) + 1
        profiles.append(profile)
        profileStore.save(profiles)
        return profile
    }

    /// Remove profile metadata. Caller is responsible for untagging entries first if desired.
    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
        profileStore.save(profiles)
    }

    /// Rename a profile. Updates both `Profile.name` and any `HostEntry.tag` references,
    /// then persists profile metadata.
    @discardableResult
    func renameProfile(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let candidate = Profile(name: trimmed, color: profiles[idx].color)
        guard candidate.isNameValid,
              !profiles.contains(where: { $0.id != id && $0.name.lowercased() == trimmed.lowercased() })
        else { return false }
        let oldName = profiles[idx].name
        profiles[idx].name = trimmed
        for i in entries.indices where entries[i].tag == oldName {
            entries[i].tag = trimmed
        }
        if let tagIdx = tags.firstIndex(where: { $0.name == oldName }) {
            tags[tagIdx].name = trimmed
        }
        profileStore.save(profiles)
        return true
    }

    func generateHostsContent() -> String {
        var lines: [String] = []

        // Preserve original comment lines at top
        for cl in commentLines {
            lines.append(cl.text)
        }

        if !commentLines.isEmpty {
            lines.append("")
        }

        // Write untagged entries first
        for entry in entries where entry.tag == nil {
            lines.append(formatEntry(entry))
        }

        // Write tagged entries grouped by tag
        for tag in tags {
            let tagEntries = entries.filter { $0.tag == tag.name }
            if tagEntries.isEmpty { continue }

            if lines.last != "" && lines.last != nil {
                lines.append("")
            }
            lines.append("## [tag:\(tag.name)]")
            for entry in tagEntries {
                lines.append(formatEntry(entry))
            }
            lines.append("## [/tag:\(tag.name)]")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func formatEntry(_ entry: HostEntry) -> String {
        if entry.isEnabled {
            var line = "\(entry.ip)\t\(entry.hostname)"
            if !entry.comment.isEmpty {
                line += " # \(entry.comment)"
            }
            return line
        } else {
            var line = "# \(entry.ip)\t\(entry.hostname)"
            if !entry.comment.isEmpty {
                line += " # \(entry.comment)"
            }
            return line
        }
    }

    private func isValidIP(_ string: String) -> Bool {
        // IPv4
        let ipv4Parts = string.split(separator: ".")
        if ipv4Parts.count == 4 && ipv4Parts.allSatisfy({ Int($0) != nil && Int($0)! >= 0 && Int($0)! <= 255 }) {
            return true
        }
        // IPv6 (simple check)
        if string.contains(":") {
            return true
        }
        return false
    }

    func addEntry(ip: String, hostname: String, comment: String, tag: String? = nil) {
        pushUndo()
        let entry = HostEntry(ip: ip, hostname: hostname, comment: comment, isEnabled: true, tag: tag)
        entries.append(entry)
        showToast("Đã thêm \(hostname)", type: .success)
    }

    func updateEntry(id: UUID, ip: String, hostname: String, comment: String, tag: String? = nil) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            pushUndo()
            entries[index].ip = ip
            entries[index].hostname = hostname
            entries[index].comment = comment
            entries[index].tag = tag
        }
    }

    // MARK: - Tag Management

    func createTag(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else {
            showToast("Tag \"\(trimmed)\" đã tồn tại", type: .error)
            return
        }
        tags.append(HostTag(name: trimmed))
        showToast("Đã tạo tag \"\(trimmed)\"", type: .success)
    }

    func renameTag(oldName: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) else {
            showToast("Tag \"\(trimmed)\" đã tồn tại", type: .error)
            return
        }
        pushUndo()
        if let tagIndex = tags.firstIndex(where: { $0.name == oldName }) {
            tags[tagIndex].name = trimmed
        }
        // Batch mutate via local copy to avoid one publisher event per entry
        var updated = entries
        for i in updated.indices where updated[i].tag == oldName {
            updated[i].tag = trimmed
        }
        entries = updated
        showToast("Đã đổi tên tag thành \"\(trimmed)\"", type: .success)
    }

    func deleteTag(name: String) {
        pushUndo()
        tags.removeAll { $0.name == name }
        var updated = entries
        for i in updated.indices where updated[i].tag == name {
            updated[i].tag = nil
        }
        entries = updated
        showToast("Đã xóa tag \"\(name)\"", type: .success)
    }

    func toggleTag(name: String) {
        pushUndo()
        let state = tagState(name: name)
        // mixed or allEnabled → turn all off; allDisabled → turn all on
        let newState = state == .allDisabled

        var updated = entries
        for i in updated.indices where updated[i].tag == name {
            updated[i].isEnabled = newState
        }
        entries = updated
    }

    enum TagState {
        case allEnabled, allDisabled, mixed
    }

    func tagState(name: String) -> TagState {
        let tagEntries = entries.filter { $0.tag == name }
        guard !tagEntries.isEmpty else { return .allDisabled }
        let allEnabled = tagEntries.allSatisfy { $0.isEnabled }
        let allDisabled = tagEntries.allSatisfy { !$0.isEnabled }
        if allEnabled { return .allEnabled }
        if allDisabled { return .allDisabled }
        return .mixed
    }

    func isTagEnabled(name: String) -> Bool {
        return tagState(name: name) == .allEnabled
    }

    func moveEntryToTag(entryId: UUID, tag: String?) {
        if let index = entries.firstIndex(where: { $0.id == entryId }) {
            pushUndo()
            entries[index].tag = tag
        }
    }

    func tagEntryCount(name: String) -> Int {
        entries.filter { $0.tag == name }.count
    }

    func deleteEntry(id: UUID) {
        pushUndo()
        entries.removeAll { $0.id == id }
    }

    @discardableResult
    func duplicateEntry(id: UUID) -> HostEntry? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        pushUndo()
        let source = entries[idx]
        let copy = HostEntry(
            ip: source.ip,
            hostname: source.hostname,
            comment: source.comment,
            isEnabled: source.isEnabled,
            isComment: source.isComment,
            tag: source.tag
        )
        entries.insert(copy, at: idx + 1)
        return copy
    }

    func toggleEntry(id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            pushUndo()
            entries[index].isEnabled.toggle()
        }
    }

    func hostnameExists(_ hostname: String) -> Bool {
        entries.contains { $0.hostname.lowercased() == hostname.lowercased() }
    }

    func filteredEntries(filter: SidebarFilter, searchText: String, selectedTag: String? = nil) -> [HostEntry] {
        var result = entries

        // Tag filter takes priority
        if let tag = selectedTag {
            result = result.filter { $0.tag == tag }
        } else {
            switch filter {
            case .all:
                break
            case .enabled:
                result = result.filter { $0.isEnabled }
            case .disabled:
                result = result.filter { !$0.isEnabled }
            case .blocking:
                result = result.filter { ($0.ip == "0.0.0.0") || ($0.ip == "127.0.0.1" && $0.hostname != "localhost") }
            }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.ip.localizedCaseInsensitiveContains(searchText) ||
                $0.hostname.localizedCaseInsensitiveContains(searchText) ||
                $0.comment.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    func entryCount(for filter: SidebarFilter) -> Int {
        switch filter {
        case .all: return entries.count
        case .enabled: return entries.filter { $0.isEnabled }.count
        case .disabled: return entries.filter { !$0.isEnabled }.count
        case .blocking: return entries.filter { $0.ip == "0.0.0.0" || ($0.ip == "127.0.0.1" && $0.hostname != "localhost") }.count
        }
    }

    private func runPrivilegedCommand(_ command: String, completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = runPrivilegedShellCommand(command)

            DispatchQueue.main.async {
                if status == errAuthorizationSuccess {
                    completion(true, nil)
                } else if status == errAuthorizationCanceled {
                    completion(false, nil) // User cancelled
                } else {
                    completion(false, "Lỗi xác thực (code: \(status))")
                }
            }
        }
    }

    private func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func applyChanges() {
        guard hasUnsavedChanges, !isApplying else { return }
        isApplying = true

        let content = generateHostsContent()
        let tempPath = NSTemporaryDirectory() + "hosts_\(UUID().uuidString)"

        do {
            try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
        } catch {
            isApplying = false
            showToast("Lỗi tạo file tạm: \(error.localizedDescription)", type: .error)
            return
        }

        let escapedTempPath = shellEscaped(tempPath)
        let command = "cp \(escapedTempPath) /etc/hosts && rm -f \(escapedTempPath) && dscacheutil -flushcache && (killall -HUP mDNSResponder 2>/dev/null || true)"

        // Suspend watcher so our own write doesn't show as "external change".
        fileWatcher.suspend()
        runPrivilegedCommand(command) { [weak self] success, error in
            guard let self = self else { return }
            self.isApplying = false

            if success {
                self.originalContent = content
                self.pristineSerialized = content
                self.rawTextDirtyOverride = false
                self.externalChangeDetected = false
                self.redoStack.removeAll()  // post-apply redo would re-create stale state
                self.showToast("Đã áp dụng thành công!", type: .success)
            } else if let error = error {
                self.showToast("Lỗi: \(error)", type: .error)
            }
            // Resume after a short delay — disk events trail the cp by a few ms.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.fileWatcher.resume()
            }
            // error == nil means user cancelled — do nothing
        }
    }

    func replaceContentFromRawText(_ text: String) {
        pushUndo()
        parseHostsContent(text)
    }

    func applyRawText(_ text: String) {
        guard !text.isEmpty, !isApplying else { return }
        isApplying = true

        let content = text.hasSuffix("\n") ? text : text + "\n"
        let tempPath = NSTemporaryDirectory() + "hosts_\(UUID().uuidString)"

        do {
            try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
        } catch {
            isApplying = false
            showToast("Lỗi tạo file tạm: \(error.localizedDescription)", type: .error)
            return
        }

        let escapedTempPath = shellEscaped(tempPath)
        let command = "cp \(escapedTempPath) /etc/hosts && rm -f \(escapedTempPath) && dscacheutil -flushcache && (killall -HUP mDNSResponder 2>/dev/null || true)"

        fileWatcher.suspend()
        runPrivilegedCommand(command) { [weak self] success, error in
            guard let self = self else { return }
            self.isApplying = false

            if success {
                self.originalContent = content
                self.parseHostsContent(content)
                self.captureClean()
                self.externalChangeDetected = false
                self.showToast("Đã áp dụng thành công!", type: .success)
            } else if let error = error {
                self.showToast("Lỗi: \(error)", type: .error)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.fileWatcher.resume()
            }
        }
    }

    func createBackup() {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let command = "cp /etc/hosts /etc/hosts.backup.\(timestamp)"

        runPrivilegedCommand(command) { [weak self] success, error in
            if success {
                self?.showToast("Đã tạo backup: hosts.backup.\(timestamp)", type: .success)
            } else if let error = error {
                self?.showToast("Lỗi tạo backup: \(error)", type: .error)
            }
        }
    }

    func exportToClipboard() {
        let content = generateHostsContent()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        showToast("Đã copy nội dung hosts vào clipboard", type: .success)
    }

    func importEntries(from text: String) {
        let lines = text.components(separatedBy: "\n")
        var added = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let withoutComment: String
            let inlineComment: String
            if let hashIndex = trimmed.firstIndex(of: "#") {
                withoutComment = String(trimmed[trimmed.startIndex..<hashIndex]).trimmingCharacters(in: .whitespaces)
                inlineComment = String(trimmed[trimmed.index(after: hashIndex)...]).trimmingCharacters(in: .whitespaces)
            } else {
                withoutComment = trimmed
                inlineComment = ""
            }

            let parts = withoutComment.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 2 && isValidIP(parts[0]) && !hostnameExists(parts[1]) {
                if added == 0 { pushUndo() }  // single snapshot for whole import
                entries.append(HostEntry(ip: parts[0], hostname: parts[1], comment: inlineComment))
                added += 1
            }
        }

        if added > 0 {
            showToast("Đã import \(added) entry mới", type: .success)
        } else {
            showToast("Không có entry mới để import", type: .info)
        }
    }

    func showToast(_ message: String, type: ToastType) {
        toast = ToastMessage(message: message, type: type)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.toast?.message == message {
                self?.toast = nil
            }
        }
    }
}
