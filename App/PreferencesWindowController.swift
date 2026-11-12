import AppKit
import ServiceManagement

final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var bookmarks: [Bookmark] = []
    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let volumeField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let autoConnectButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var selectedID: UUID?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.favoritesTitle
        window.center()
        self.init(window: window)
        window.contentView = buildContent()
        reload()
    }

    func showWindow(prefill: Bookmark?) {
        window?.title = L10n.favoritesTitle
        showWindow(nil)
        if let prefill {
            applyForm(prefill)
            selectedID = nil
        }
    }

    private func buildContent() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true

        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 260
        tableView.addTableColumn(column)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(selectionChanged)
        scroll.documentView = tableView

        let form = NSStackView()
        form.translatesAutoresizingMaskIntoConstraints = false
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        func labeledField(_ title: String, _ field: NSTextField) -> NSView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(equalToConstant: 130).isActive = true
            field.translatesAutoresizingMaskIntoConstraints = false
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            field.heightAnchor.constraint(equalToConstant: 22).isActive = true
            row.addArrangedSubview(label)
            row.addArrangedSubview(field)
            return row
        }

        form.addArrangedSubview(labeledField(L10n.displayName, nameField))
        form.addArrangedSubview(labeledField(L10n.host, hostField))
        form.addArrangedSubview(labeledField(L10n.port, portField))
        form.addArrangedSubview(labeledField(L10n.volume, volumeField))
        form.addArrangedSubview(labeledField(L10n.username, userField))
        form.addArrangedSubview(labeledField(L10n.password, passwordField))

        autoConnectButton.title = L10n.connectAtLogin
        launchAtLoginButton.title = L10n.launchAtLogin
        launchAtLoginButton.state = (UserDefaults.standard.object(forKey: AppConstants.launchAtLoginKey) as? Bool ?? true) ? .on : .off
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        form.addArrangedSubview(autoConnectButton)
        form.addArrangedSubview(launchAtLoginButton)

        let addButton = NSButton(title: L10n.addUpdate, target: self, action: #selector(saveBookmark))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        let removeButton = NSButton(title: L10n.remove, target: self, action: #selector(removeBookmark))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        let connectButton = NSButton(title: L10n.connect, target: self, action: #selector(connectSelected))
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.keyEquivalent = "\r"

        root.addSubview(scroll)
        root.addSubview(form)
        root.addSubview(addButton)
        root.addSubview(removeButton)
        root.addSubview(connectButton)

        // Wrapper so Auto Layout works inside the window content view.
        let container = NSView()
        container.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 720),
            root.heightAnchor.constraint(equalToConstant: 400),

            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scroll.widthAnchor.constraint(equalToConstant: 280),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            form.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16),

            addButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            addButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            addButton.heightAnchor.constraint(equalToConstant: 28),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            removeButton.heightAnchor.constraint(equalToConstant: 28),

            // Right-align Connect with the form fields (label 130 + spacing 8 + field 260).
            connectButton.trailingAnchor.constraint(equalTo: form.leadingAnchor, constant: 130 + 8 + 260),
            connectButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            connectButton.heightAnchor.constraint(equalToConstant: 28),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])

        return container
    }

    private func reload() {
        bookmarks = BookmarkStore.shared.load()
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { bookmarks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FavoriteCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            text.drawsBackground = false
            text.isBezeled = false
            text.isEditable = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = bookmarks[row].displayName
        return cell
    }

    @objc private func selectionChanged() {
        let row = tableView.selectedRow
        guard row >= 0, row < bookmarks.count else { return }
        let bookmark = bookmarks[row]
        selectedID = bookmark.id
        applyForm(bookmark)
        let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
        passwordField.stringValue = KeychainStore.password(
            account: bookmark.username,
            servers: servers,
            port: bookmark.port
        ) ?? ""
    }

    private func applyForm(_ bookmark: Bookmark) {
        nameField.stringValue = bookmark.displayName
        hostField.stringValue = bookmark.host
        portField.stringValue = String(bookmark.port)
        volumeField.stringValue = bookmark.volume
        userField.stringValue = bookmark.username
        autoConnectButton.state = bookmark.autoConnect ? .on : .off
    }

    @objc private func saveBookmark() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let volume = volumeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !volume.isEmpty else { return }
        let port = Int(portField.stringValue) ?? 548
        let bookmark = Bookmark(
            id: selectedID ?? UUID(),
            displayName: nameField.stringValue,
            host: host,
            port: port,
            volume: volume,
            username: userField.stringValue,
            autoConnect: autoConnectButton.state == .on
        )
        BookmarkStore.shared.upsert(bookmark)
        if !passwordField.stringValue.isEmpty, !bookmark.username.isEmpty {
            let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
            try? KeychainStore.savePassword(
                passwordField.stringValue,
                account: bookmark.username,
                servers: servers,
                port: bookmark.port
            )
        }
        selectedID = bookmark.id
        reload()
        NotificationCenter.default.post(name: .init("ClassicAFPBookmarksChanged"), object: nil)
    }

    @objc private func removeBookmark() {
        guard let selectedID else { return }
        if let bookmark = bookmarks.first(where: { $0.id == selectedID }) {
            let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
            KeychainStore.deletePassword(account: bookmark.username, servers: servers, port: bookmark.port)
        }
        BookmarkStore.shared.remove(id: selectedID)
        self.selectedID = nil
        reload()
        NotificationCenter.default.post(name: .init("ClassicAFPBookmarksChanged"), object: nil)
    }

    @objc private func connectSelected() {
        saveBookmark()
        guard let selectedID,
              let bookmark = BookmarkStore.shared.load().first(where: { $0.id == selectedID })
        else { return }
        let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
        let password = passwordField.stringValue.isEmpty
            ? KeychainStore.password(account: bookmark.username, servers: servers, port: bookmark.port)
            : passwordField.stringValue
        Task { @MainActor in
            await MountController.shared.mount(bookmark, password: password)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = launchAtLoginButton.state == .on
        UserDefaults.standard.set(enabled, forKey: AppConstants.launchAtLoginKey)
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
