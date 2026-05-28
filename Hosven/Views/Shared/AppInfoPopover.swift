import SwiftUI

/// Popover triggered by the title-bar gear button. Shows app identity and
/// quick menu: Giới thiệu, Kiểm tra cập nhật, Cài đặt, Feedback, Trang chủ.
///
/// Update check is delegated to Sparkle via `AutoUpdater` — Sparkle owns all
/// dialogs (no-update toast, install prompt, progress, relaunch).
struct AppInfoPopover: View {
    var onDismiss: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @Environment(AutoUpdater.self) private var updater

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.p3) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                menuItem(icon: "info.circle", label: "Giới thiệu", action: showAbout)
                menuItem(icon: "arrow.down.circle", label: "Kiểm tra cập nhật", action: checkForUpdates)
                menuItem(icon: "bubble.left.and.bubble.right", label: "Gửi feedback", action: openFeedback)
                menuItem(icon: "gearshape", label: "Cài đặt…", action: openSettings)
            }
            Divider()
            menuItem(icon: "link", label: "Trang chủ dự án", action: openHomepage)
        }
        .padding(DSSpacing.p3)
        .frame(width: 240)
    }

    private var header: some View {
        HStack(spacing: DSSpacing.p2) {
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundStyle(Color.dsProfilePurple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hosven")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                Text("Phiên bản \(appVersion) (\(buildNumber))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsTextSecondary)
            }
        }
    }

    private func menuItem(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onDismiss()
        } label: {
            HStack(spacing: DSSpacing.p2) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(Color.dsTextSecondary)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dsTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.p2)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: - Actions

    private func checkForUpdates() {
        updater.checkForUpdates()
    }

    private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private func openHomepage() {
        guard let url = URL(string: "https://github.com/twan-nguyen/hosven") else { return }
        openURL(url)
    }

    private func openFeedback() {
        var components = URLComponents(string: "https://github.com/twan-nguyen/hosven/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Feedback: "),
            URLQueryItem(name: "body", value: """
            ## Feedback


            ---
            Hosven \(appVersion) (\(buildNumber))
            \(ProcessInfo.processInfo.operatingSystemVersionString)
            """)
        ]

        guard let url = components?.url else { return }
        openURL(url)
    }
}

/// Highlight-on-hover row used for popover menu items.
private struct MenuRowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        configuration.isPressed
                            ? Color.dsProfilePurple.opacity(0.25)
                            : (isHovering ? Color.white.opacity(0.06) : Color.clear)
                    )
            )
            .onHover { isHovering = $0 }
    }
}
