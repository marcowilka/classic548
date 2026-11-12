import AppKit

// Retain the delegate strongly — NSApplication.delegate is weak.
final class AppMain {
    static let shared = AppMain()
    let app = NSApplication.shared
    let delegate = AppDelegate()

    func run() {
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

AppMain.shared.run()
