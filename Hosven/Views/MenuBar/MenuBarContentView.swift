import SwiftUI

/// MenuBarExtra dropdown content. Two actions: open the main window, quit.
/// Profile switching has moved entirely into the in-app sidebar to keep the
/// menu bar minimal.
struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Mở Hosven") {
            showMainWindow()
        }
        .keyboardShortcut("o", modifiers: .command)

        Button("Thoát") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        openWindow(id: "main")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

            for window in NSApp.windows where window.canBecomeKey {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                return
            }
        }
    }
}
