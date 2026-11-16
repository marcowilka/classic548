import AppKit

/// Bring agent (LSUIElement) windows to the front so they are not lost behind other apps.
enum AppWindowPresentation {
    static func present(_ controller: NSWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        guard let window = controller.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
