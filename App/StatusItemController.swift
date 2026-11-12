import AppKit

@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let bonjour: BonjourBrowser
    private var preferencesWindow: PreferencesWindowController?
    private var diagnosticsWindow: DiagnosticsWindowController?

    init(bonjour: BonjourBrowser) {
        self.bonjour = bonjour
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "ClassicAFP")
            button.image?.isTemplate = true
        }
        MountController.shared.onChange = { [weak self] in
            self?.rebuildMenu()
        }
        bonjour.onUpdate = { [weak self] _ in
            Task { @MainActor in self?.rebuildMenu() }
        }
        NotificationCenter.default.addObserver(
            forName: .init("ClassicAFPBookmarksChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuildMenu() }
        }
    }

    func start() {
        rebuildMenu()
    }

    func setStatus(_ text: String) {
        MountController.shared.statusMessage = text
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: MountController.shared.statusMessage, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let bookmarks = BookmarkStore.shared.load()
        if bookmarks.isEmpty {
            let empty = NSMenuItem(title: L10n.noFavorites, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for bookmark in bookmarks {
                let mounted = MountController.shared.isMounted(bookmark)
                if mounted {
                    let header = NSMenuItem(
                        title: bookmark.displayName,
                        action: nil,
                        keyEquivalent: ""
                    )
                    header.isEnabled = false
                    menu.addItem(header)

                    let reveal = NSMenuItem(
                        title: L10n.openInFinder,
                        action: #selector(revealBookmark(_:)),
                        keyEquivalent: ""
                    )
                    reveal.target = self
                    reveal.representedObject = bookmark.id.uuidString
                    menu.addItem(reveal)

                    let eject = NSMenuItem(
                        title: L10n.eject,
                        action: #selector(toggleBookmark(_:)),
                        keyEquivalent: ""
                    )
                    eject.target = self
                    eject.representedObject = bookmark.id.uuidString
                    menu.addItem(eject)
                } else {
                    let item = NSMenuItem(
                        title: L10n.connectNamed(bookmark.displayName),
                        action: #selector(toggleBookmark(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = bookmark.id.uuidString
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(.separator())

        if !bonjour.services.isEmpty {
            let discovered = NSMenuItem(title: L10n.discoveredServers, action: nil, keyEquivalent: "")
            discovered.isEnabled = false
            menu.addItem(discovered)
            for service in bonjour.services {
                let item = NSMenuItem(title: "\(service.name) (\(service.host))", action: #selector(addDiscovered(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = "\(service.host)|\(service.port)|\(service.name)"
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let prefs = NSMenuItem(title: L10n.favoritesSettings, action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let diag = NSMenuItem(title: L10n.diagnostics, action: #selector(showDiagnostics), keyEquivalent: "d")
        diag.target = self
        menu.addItem(diag)

        let ext = NSMenuItem(title: L10n.openFSExtensions, action: #selector(openExtensions), keyEquivalent: "")
        ext.target = self
        menu.addItem(ext)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleBookmark(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let bookmark = BookmarkStore.shared.load().first(where: { $0.id == id })
        else { return }

        Task {
            if MountController.shared.isMounted(bookmark) {
                await MountController.shared.unmount(bookmark)
            } else {
                if bookmark.guestAccess {
                    await MountController.shared.mount(bookmark, password: nil)
                } else {
                    let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
                    let password = KeychainStore.password(
                        account: bookmark.username,
                        servers: servers,
                        port: bookmark.port
                    )
                    if password == nil, !bookmark.username.isEmpty {
                        promptPassword(for: bookmark)
                    } else {
                        await MountController.shared.mount(bookmark, password: password)
                    }
                }
            }
            rebuildMenu()
        }
    }

    @objc private func revealBookmark(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let bookmark = BookmarkStore.shared.load().first(where: { $0.id == id })
        else { return }
        MountController.shared.reveal(bookmark)
    }

    @objc private func addDiscovered(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return }
        let host = parts[0]
        let port = Int(parts[1]) ?? 548
        let name = parts[2]
        let bookmark = Bookmark(displayName: name, host: host, port: port, volume: "", username: "")
        presentPreferences(prefill: bookmark)
    }

    @objc private func showPreferences() {
        presentPreferences(prefill: nil)
    }

    private func presentPreferences(prefill: Bookmark?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
        }
        preferencesWindow?.showWindow(prefill: prefill)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openExtensions() {
        MountController.shared.openExtensionSettings()
    }

    @objc private func showDiagnostics() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindowController()
        }
        diagnosticsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            _ = await MountController.shared.refreshExtensionStatus()
        }
    }

    private func promptPassword(for bookmark: Bookmark) {
        let alert = NSAlert()
        alert.messageText = L10n.passwordTitle(bookmark.displayName)
        alert.informativeText = L10n.passwordBody(bookmark.username)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.connect)
        alert.addButton(withTitle: L10n.cancel)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
        try? KeychainStore.savePassword(
            password,
            account: bookmark.username,
            servers: servers,
            port: bookmark.port
        )
        Task {
            await MountController.shared.mount(bookmark, password: password)
            rebuildMenu()
        }
    }
}
