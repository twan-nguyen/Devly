import SwiftUI

@main
struct HosvenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var hostsManager = HostsFileManager()
    @State private var envManager = EnvFileManager()
    @State private var autoUpdater = AutoUpdater()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra: Bool = true

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView()
                .environment(hostsManager)
                .environment(envManager)
                .environment(autoUpdater)
                .frame(minWidth: 880, minHeight: 540)
        }
        // .hiddenTitleBar collapses the native title bar so our custom TitleBarView
        // sits flush at the top. MenuBarExtra side effects from older SDKs no
        // longer apply since we switched to .menuBarExtraStyle(.menu).
        // WindowChromeConfigurator still force-shows traffic lights as defense.
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Hoàn tác") { hostsManager.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!hostsManager.canUndo)
                Button("Làm lại") { hostsManager.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!hostsManager.canRedo)
            }
            CommandGroup(after: .textEditing) {
                Button("Tìm kiếm") {
                    hostsManager.isSearchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Profile") {
                profileShortcutCommands
                Divider()
                Button("Bỏ chọn profile") {
                    hostsManager.switchProfile(to: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(hostsManager)
                .environment(envManager)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContentView()
                .environment(hostsManager)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    /// Monochrome menu bar icon styled after the AppIcon's cascading cards.
    /// Stays static across profile switches; profile state lives in the dropdown.
    /// Uses an SF Symbol because the menu bar rasterizes its label and arbitrary
    /// SwiftUI shapes/masks render as a blank disc.
    @ViewBuilder
    private var menuBarLabel: some View {
        Image(systemName: "rectangle.stack.fill")
    }

    /// One menu item per profile (⌘1..⌘9). Hidden in production menu via empty title? — kept visible
    /// so users can discover the shortcut. macOS folds it into the Profile menu.
    @ViewBuilder
    private var profileShortcutCommands: some View {
        ForEach(hostsManager.profiles, id: \.id) { profile in
            if let n = profile.shortcutNumber, (1...9).contains(n) {
                Button("Switch to \(profile.name)") {
                    hostsManager.switchProfile(to: profile.id)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if shouldHideDockAfterLastWindowClosed {
            sender.setActivationPolicy(.accessory)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseAuthorization()
    }

    private var shouldHideDockAfterLastWindowClosed: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showMenuBarExtra") == nil {
            return true
        }
        return defaults.bool(forKey: "showMenuBarExtra")
    }
}
