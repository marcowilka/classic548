import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let bonjour = BonjourBrowser()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticsLog.shared.info("ClassicAFP launching")
        statusController = StatusItemController(bonjour: bonjour)
        statusController?.start()
        bonjour.start()

        do {
            try DaemonLauncher.shared.ensureRunning()
            DiagnosticsLog.shared.info("afpsld started")
        } catch {
            DiagnosticsLog.shared.error(error, context: "daemon")
            statusController?.setStatus(L10n.helperMissing)
        }

        // Fresh menu status — never show a previous session's login error.
        MountController.shared.resetStatusForLaunch()
        // Adopt volumes that survived a previous quit (daemon left running).
        MountController.shared.reconcileMountedVolumes()

        Task { @MainActor in
            _ = await MountController.shared.refreshExtensionStatus()
        }

        registerLoginItemIfNeeded()
        autoConnectFavorites()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(networkChanged),
            name: .init("com.apple.system.config.network_change"),
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        bonjour.stop()
        // Clean unmount then stop helper — matches user expectation that Quit
        // removes the volume (Eject uses the same diskutil unmount path).
        MountController.shared.unmountAllSync()
        DaemonLauncher.shared.stop()
    }

    @objc private func systemDidWake() {
        Task { @MainActor in
            do {
                try DaemonLauncher.shared.ensureRunning()
            } catch {
                DiagnosticsLog.shared.error(error, context: "wake/daemon")
            }
            autoConnectFavorites()
        }
    }

    @objc private func networkChanged() {
        Task { @MainActor in
            do {
                try DaemonLauncher.shared.ensureRunning()
            } catch {
                DiagnosticsLog.shared.error(error, context: "network/daemon")
            }
        }
    }

    private func registerLoginItemIfNeeded() {
        let enabled = UserDefaults.standard.object(forKey: AppConstants.launchAtLoginKey) as? Bool ?? true
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // Login item registration can fail before first user approval; ignore.
        }
    }

    private func autoConnectFavorites() {
        let bookmarks = BookmarkStore.shared.load().filter(\.autoConnect)
        Task { @MainActor in
            MountController.shared.reconcileMountedVolumes()
            for bookmark in bookmarks {
                if MountController.shared.isMounted(bookmark) {
                    continue
                }
                let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
                let password = KeychainStore.password(
                    account: bookmark.username,
                    servers: servers,
                    port: bookmark.port
                )
                await MountController.shared.mountForAutoConnect(bookmark, password: password)
            }
        }
    }
}
