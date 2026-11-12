import AppKit
import ServiceManagement

final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var bookmarks: [Bookmark] = []
    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let volumePopup = NSPopUpButton()
    private let refreshVolumesButton = NSButton()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let autoConnectButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var selectedID: UUID?
    private var knownVolumes: [String] = []
    /// Host:port the current `knownVolumes` were fetched for (nil = none / stale).
    private var knownVolumesIdentity: String?
    private var volumeFetchGeneration = 0
    private var isFetchingVolumes = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.favoritesTitle
        window.center()
        self.init(window: window)
        window.contentView = buildContent()
        reload()
        rebuildVolumePopup(preserving: nil)
        updateVolumeFetchControls()
    }

    func showWindow(prefill: Bookmark?) {
        window?.title = L10n.favoritesTitle
        showWindow(nil)
        if let prefill {
            applyForm(prefill)
            selectedID = nil
            passwordField.stringValue = ""
            updateVolumeFetchControls()
            // Volume list loads only after password Enter/Tab or Refresh — avoid failed logins.
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
        form.addArrangedSubview(labeledField(L10n.username, userField))
        form.addArrangedSubview(labeledField(L10n.password, passwordField))

        let volumeRow = NSStackView()
        volumeRow.orientation = .horizontal
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        let volumeLabel = NSTextField(labelWithString: L10n.volume)
        volumeLabel.alignment = .right
        volumeLabel.setContentHuggingPriority(.required, for: .horizontal)
        volumeLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true
        volumePopup.translatesAutoresizingMaskIntoConstraints = false
        volumePopup.widthAnchor.constraint(equalToConstant: 260).isActive = true
        volumePopup.heightAnchor.constraint(equalToConstant: 24).isActive = true
        volumePopup.autoenablesItems = false
        refreshVolumesButton.translatesAutoresizingMaskIntoConstraints = false
        refreshVolumesButton.bezelStyle = .flexiblePush
        refreshVolumesButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.refreshVolumes)
        refreshVolumesButton.imagePosition = .imageOnly
        refreshVolumesButton.toolTip = L10n.refreshVolumes
        refreshVolumesButton.target = self
        refreshVolumesButton.action = #selector(refreshVolumesClicked)
        refreshVolumesButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        refreshVolumesButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        volumeRow.addArrangedSubview(volumeLabel)
        volumeRow.addArrangedSubview(volumePopup)
        volumeRow.addArrangedSubview(refreshVolumesButton)
        form.addArrangedSubview(volumeRow)

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

        let container = NSView()
        container.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 760),
            root.heightAnchor.constraint(equalToConstant: 420),

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

            connectButton.trailingAnchor.constraint(equalTo: form.leadingAnchor, constant: 130 + 8 + 260 + 8 + 32),
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

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === hostField || field === portField || field === userField || field === passwordField {
            // Keep refresh enabled state + placeholder in sync while typing credentials.
            rebuildVolumePopup(preserving: selectedVolumeName.isEmpty ? nil : selectedVolumeName)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === hostField || field === portField {
            discardStaleVolumesIfNeeded(preserving: selectedVolumeName)
        }
        updateVolumeFetchControls()
        // Volume list only on password commit (Enter / Tab / focus loss) or Refresh — not per keystroke.
        guard field === passwordField, canLoadVolumes else { return }
        scheduleVolumeFetch(immediate: true)
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
        updateVolumeFetchControls()
        rebuildVolumePopup(preserving: bookmark.volume)
    }

    private func applyForm(_ bookmark: Bookmark) {
        nameField.stringValue = bookmark.displayName
        hostField.stringValue = bookmark.host
        portField.stringValue = String(bookmark.port)
        userField.stringValue = bookmark.username
        autoConnectButton.state = bookmark.autoConnect ? .on : .off
        discardStaleVolumesIfNeeded(preserving: bookmark.volume)
        updateVolumeFetchControls()
    }

    private var selectedVolumeName: String {
        guard let title = volumePopup.titleOfSelectedItem,
              title != L10n.selectVolume,
              title != L10n.loadingVolumes,
              title != L10n.noVolumes,
              title != L10n.enterCredentials
        else { return "" }
        return title
    }

    private var canLoadVolumes: Bool {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && !user.isEmpty && resolvedPassword() != nil
    }

    private func updateVolumeFetchControls() {
        let ready = canLoadVolumes
        refreshVolumesButton.isEnabled = ready && !isFetchingVolumes
        refreshVolumesButton.toolTip = ready ? L10n.refreshVolumes : L10n.refreshNeedsCredentials
    }

    private func volumeIdentity(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    private func currentVolumeIdentity() -> String {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue) ?? 548
        return volumeIdentity(host: host, port: port)
    }

    /// Drop volume names fetched for a different host/port; keep only the sticky selection.
    private func discardStaleVolumesIfNeeded(preserving preferred: String?) {
        let identity = currentVolumeIdentity()
        if knownVolumesIdentity != identity {
            knownVolumes = []
            knownVolumesIdentity = nil
        }
        rebuildVolumePopup(preserving: preferred)
    }

    private func rebuildVolumePopup(preserving preferred: String?) {
        let keep = preferred?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never surface names that belong to another host.
        let identity = currentVolumeIdentity()
        let itemsFromServer = (knownVolumesIdentity == identity) ? knownVolumes : []
        var items = itemsFromServer
        if let keep, !keep.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(keep) == .orderedSame }) {
            items.insert(keep, at: 0)
        }

        volumePopup.removeAllItems()
        volumePopup.addItem(withTitle: L10n.selectVolume)
        if isFetchingVolumes {
            volumePopup.addItem(withTitle: L10n.loadingVolumes)
            volumePopup.selectItem(at: 1)
            volumePopup.isEnabled = false
            updateVolumeFetchControls()
            return
        }

        if !canLoadVolumes {
            volumePopup.isEnabled = false
            if items.isEmpty {
                volumePopup.addItem(withTitle: L10n.enterCredentials)
                volumePopup.selectItem(at: 1)
            } else {
                for name in items {
                    volumePopup.addItem(withTitle: name)
                }
                if let keep, let idx = volumePopup.itemTitles.firstIndex(of: keep) {
                    volumePopup.selectItem(at: idx)
                } else {
                    volumePopup.selectItem(at: 0)
                }
            }
            updateVolumeFetchControls()
            return
        }

        volumePopup.isEnabled = true
        if items.isEmpty {
            volumePopup.addItem(withTitle: L10n.noVolumes)
            volumePopup.selectItem(at: 0)
            updateVolumeFetchControls()
            return
        }

        for name in items {
            volumePopup.addItem(withTitle: name)
        }
        if let keep, let idx = volumePopup.itemTitles.firstIndex(of: keep) {
            volumePopup.selectItem(at: idx)
        } else if items.count == 1 {
            volumePopup.selectItem(at: 1)
        } else {
            volumePopup.selectItem(at: 0)
        }
        updateVolumeFetchControls()
    }

    @objc private func refreshVolumesClicked() {
        guard canLoadVolumes else {
            updateVolumeFetchControls()
            return
        }
        scheduleVolumeFetch(immediate: true, showAlertOnError: true)
    }

    private func scheduleVolumeFetch(immediate: Bool, showAlertOnError: Bool = false) {
        volumeFetchGeneration += 1
        let generation = volumeFetchGeneration
        let delay: TimeInterval = immediate ? 0 : 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.volumeFetchGeneration else { return }
            self.fetchVolumes(generation: generation, showAlertOnError: showAlertOnError)
        }
    }

    private func resolvedPassword() -> String? {
        let typed = passwordField.stringValue
        if !typed.isEmpty { return typed }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue) ?? 548
        guard !host.isEmpty, !user.isEmpty else { return nil }
        let servers = [host, HostResolver.preferredAFPHost(host)]
        return KeychainStore.password(account: user, servers: servers, port: port)
    }

    private func fetchVolumes(generation: Int, showAlertOnError: Bool) {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portField.stringValue) ?? 548
        let identity = volumeIdentity(host: host, port: port)
        let preserving = selectedVolumeName.isEmpty ? nil : selectedVolumeName

        guard let password = resolvedPassword(), !host.isEmpty, !user.isEmpty else {
            discardStaleVolumesIfNeeded(preserving: preserving)
            updateVolumeFetchControls()
            return
        }

        isFetchingVolumes = true
        updateVolumeFetchControls()
        rebuildVolumePopup(preserving: preserving)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<[String], Error>
            do {
                let names = try AFPVolumeBrowser.listVolumes(
                    host: host,
                    port: port,
                    username: user,
                    password: password
                )
                result = .success(names)
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard let self, generation == self.volumeFetchGeneration else { return }
                self.isFetchingVolumes = false
                // Host may have changed while the request was in flight.
                guard self.currentVolumeIdentity() == identity else {
                    self.discardStaleVolumesIfNeeded(preserving: self.selectedVolumeName)
                    self.updateVolumeFetchControls()
                    return
                }
                switch result {
                case .success(let names):
                    self.knownVolumes = names
                    self.knownVolumesIdentity = identity
                    self.rebuildVolumePopup(preserving: preserving)
                    DiagnosticsLog.shared.info("Listed \(names.count) AFP volume(s) on \(host)")
                case .failure(let error):
                    self.discardStaleVolumesIfNeeded(preserving: preserving)
                    let message = L10n.volumeLoadFailed(error.localizedDescription)
                    DiagnosticsLog.shared.error(error, context: "listVolumes")
                    if showAlertOnError {
                        let alert = NSAlert()
                        alert.messageText = L10n.volume
                        alert.informativeText = message
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: L10n.cancel)
                        alert.runModal()
                    }
                }
                self.updateVolumeFetchControls()
            }
        }
    }

    @objc private func saveBookmark() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let volume = selectedVolumeName
        guard !host.isEmpty, !volume.isEmpty else { return }
        let port = Int(portField.stringValue) ?? 548
        let existing = BookmarkStore.shared.load()

        // Identity is host+port+volume — same host with another volume is a new favorite.
        let id: UUID
        if let selectedID,
           let selected = existing.first(where: { $0.id == selectedID }),
           selected.matchesMountTarget(host: host, port: port, volume: volume) {
            id = selectedID
        } else if let match = existing.first(where: { $0.matchesMountTarget(host: host, port: port, volume: volume) }) {
            id = match.id
        } else {
            id = UUID()
        }

        let bookmark = Bookmark(
            id: id,
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
        if let row = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        NotificationCenter.default.post(name: .init("ClassicAFPBookmarksChanged"), object: nil)
    }

    @objc private func removeBookmark() {
        guard let selectedID else { return }
        if let bookmark = bookmarks.first(where: { $0.id == selectedID }) {
            let othersStillNeedPassword = BookmarkStore.shared.load().contains {
                $0.id != selectedID
                    && $0.port == bookmark.port
                    && !$0.username.isEmpty
                    && $0.username == bookmark.username
                    && ($0.host.caseInsensitiveCompare(bookmark.host) == .orderedSame
                        || HostResolver.preferredAFPHost($0.host)
                            .caseInsensitiveCompare(HostResolver.preferredAFPHost(bookmark.host)) == .orderedSame)
            }
            if !othersStillNeedPassword {
                let servers = [bookmark.host, HostResolver.preferredAFPHost(bookmark.host)]
                KeychainStore.deletePassword(account: bookmark.username, servers: servers, port: bookmark.port)
            }
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
