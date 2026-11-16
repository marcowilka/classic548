import AFPBridge
import Foundation
import FSKit
import os.log

private let log = Logger(subsystem: AppConstants.fsExtensionBundleID, category: "Volume")

final class AFPVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler, FSVolume.OpenCloseHandler {
    private let client = AFPClient()
    private let components: AFPURLComponents
    private var rootItem = AFPItem.root()
    private var itemsByPath: [String: AFPItem] = [:]
    private var nextID: UInt64 = 2
    private let queue = DispatchQueue(label: "de.marcowilka.classic548.AFPVolume", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<UUID>()
    private let queueToken = UUID()

    init(url: URL) throws {
        guard let parsed = AFPURLComponents.parse(url) else {
            throw fs_error(.EINVAL, "Invalid afp URL")
        }
        self.components = parsed
        let volumeName = FSFileName(string: parsed.volume.isEmpty ? parsed.host : parsed.volume)
        super.init(
            volumeID: FSVolume.Identifier(uuid: UUID()),
            volumeName: volumeName
        )
        queue.setSpecific(key: queueKey, value: queueToken)
        itemsByPath["/"] = rootItem
        log.info("AFPVolume created for \(parsed.host, privacy: .public)/\(parsed.volume, privacy: .public)")
    }

    /// Safe from any thread. Never call `queue.sync` while already on `queue`.
    func shutdown() {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            shutdownLocked()
        } else {
            queue.sync { self.shutdownLocked() }
        }
    }

    private func syncOnVolumeQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == queueToken {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private func shutdownLocked() {
        clearAllOpenHandlesLocked()
        try? client.detach()
        try? client.disconnect()
    }

    private func clearAllOpenHandlesLocked() {
        for item in itemsByPath.values {
            forceCloseOpenFork(item, reason: "clearAll")
        }
    }

    private func forceCloseOpenFork(_ item: AFPItem, reason: String) {
        guard let state = item.openState else { return }
        item.openState = nil
        do {
            try client.close(.init(fileID: state.fileID))
            extensionTrace("\(reason) force-closed fork path=\(item.path) fileID=\(state.fileID)")
        } catch {
            extensionTrace(
                "\(reason) close fork failed path=\(item.path) fileID=\(state.fileID): \(error)"
            )
        }
    }

    private func removePath(_ item: AFPItem) throws {
        if item.itemType == .directory {
            try client.rmdir(item.path)
        } else {
            try client.unlink(item.path)
        }
    }

    private func invalidateSessionLocked() {
        clearAllOpenHandlesLocked()
        try? client.detach()
        try? client.disconnect()
        extensionTrace("session invalidated — opens cleared")
    }

    /// Reconnect once for idempotent ops when the AFP session went stale.
    private func withIdempotentSessionRetry<T>(_ body: () throws -> T) throws -> T {
        do {
            try ensureSession()
            return try body()
        } catch let error as AFPError where error.isSessionStale {
            extensionTrace("idempotent retry after stale session: \(error)")
            invalidateSessionLocked()
            try ensureSession()
            return try body()
        } catch let error as NSError where Self.isPOSIXSessionStale(error) {
            extensionTrace("idempotent retry after POSIX stale: \(error)")
            invalidateSessionLocked()
            try ensureSession()
            return try body()
        }
    }

    private static func isPOSIXSessionStale(_ error: NSError) -> Bool {
        guard error.domain == NSPOSIXErrorDomain else { return false }
        switch Int32(error.code) {
        case ECONNRESET, ETIMEDOUT, ENOTCONN, EPIPE, ENETDOWN, ENETUNREACH, EHOSTUNREACH:
            return true
        default:
            return false
        }
    }

    // MARK: - Capabilities / PathConf

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = false
        caps.supportsSymbolicLinks = false
        caps.supportsHiddenFiles = true
        caps.supports64BitObjectIDs = true
        caps.supportsFastStatFS = false
        caps.doesNotSupportVolumeSizes = false
        caps.caseFormat = .insensitiveCasePreserving
        caps.doesNotSupportSettingFilePermissions = false
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: AppConstants.fsShortName)
        result.blockSize = 4096
        result.ioSize = 65536
        do {
            let st = try syncOnVolumeQueue { try client.statfs("/") }
            result.blockSize = st.f_bsize > 0 ? Int(st.f_bsize) : 4096
            result.totalBlocks = UInt64(st.f_blocks)
            result.availableBlocks = UInt64(st.f_bavail)
            result.freeBlocks = UInt64(st.f_bfree)
            result.totalFiles = UInt64(st.f_files)
            result.freeFiles = UInt64(st.f_ffree)
        } catch {
            // Signal unknown capacity instead of zeros that look like a full disk.
            result.totalBlocks = 1
            result.availableBlocks = 1
            result.freeBlocks = 1
            result.totalFiles = 1
            result.freeFiles = 1
        }
        return result
    }

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSizeInBits: Int { 64 }
    var maximumXattrSizeInBits: Int { 16 }

    // MARK: - Lifecycle (Handler)

    func activateVolume(options: FSTaskOptions, replyHandler reply: @escaping (FSActivateResult?, (any Error)?) -> Void) {
        queue.async {
            do {
                try self.ensureSession()
                let st = try self.client.stat("/")
                self.rootItem.mode = st.st_mode
                self.rootItem.mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                log.info("activateVolume OK")
                reply(FSActivateResult(rootItem: self.rootItem), nil)
            } catch {
                log.error("activate failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, fs_bridge(error))
            }
        }
    }

    func deactivateVolume(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        queue.async {
            self.shutdownLocked()
            reply(nil)
        }
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        queue.async {
            self.shutdownLocked()
            reply()
        }
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        queue.async {
            if let afpItem = item as? AFPItem, afpItem.path != "/" {
                self.itemsByPath.removeValue(forKey: afpItem.path)
            }
            reply(nil)
        }
    }

    // MARK: - Lookup / Attributes

    func lookupItem(
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSLookupItemResult?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? AFPItem else {
            reply(nil, fs_error(.ENOTDIR, "Not a directory"))
            return
        }
        let childName = name.string ?? ""
        let childPath = join(directory.path, childName)
        queue.async {
            do {
                try self.ensureSession()
                let item = try self.item(at: childPath, name: childName, parent: directory)
                let attrs = self.attributes(for: item, request: FSLookupItemResult.requestedAttributes)
                reply(FSLookupItemResult(foundItem: item, itemName: FSFileName(string: childName), itemAttributes: attrs), nil)
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSGetAttributesResult?, (any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem else {
            reply(nil, fs_error(.EINVAL, "Bad item"))
            return
        }
        queue.async {
            do {
                try self.ensureSession()
                let st = try self.client.stat(item.path)
                item.size = UInt64(st.st_size)
                item.mode = st.st_mode
                item.mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                item.itemType = ((st.st_mode & S_IFMT) == S_IFDIR) ? .directory : .file
                let attrs = self.attributes(for: item, request: desiredAttributes)
                reply(FSGetAttributesResult(attributes: attrs), nil)
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSSetAttributesResult?, (any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem else {
            reply(nil, fs_error(.EINVAL, "Bad item"))
            return
        }
        queue.async {
            do {
                try self.ensureSession()
                if newAttributes.isValid(.size), item.itemType == .file {
                    try self.client.truncate(item.path, size: newAttributes.size)
                    item.size = newAttributes.size
                }
                if newAttributes.isValid(.mode) {
                    try self.client.chmod(item.path, mode: mode_t(newAttributes.mode))
                    item.mode = mode_t(newAttributes.mode)
                }
                let attrs = self.attributes(for: item, request: FSSetAttributesResult.requestedAttributes)
                reply(FSSetAttributesResult(attributes: attrs, freeSpace: nil), nil)
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    // MARK: - Directory

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        context: FSContext,
        replyHandler reply: @escaping (FSEnumerateDirectoryResult?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? AFPItem else {
            reply(nil, fs_error(.ENOTDIR, "Not a directory"))
            return
        }
        queue.async {
            do {
                var start = Int(cookie.rawValue)
                let currentVerifier: FSDirectoryVerifier = verifier == .initial
                    ? FSDirectoryVerifier(rawValue: UInt64(Date().timeIntervalSince1970))
                    : verifier
                let page = try self.withIdempotentSessionRetry {
                    try self.client.readDirectory(directory.path, start: start, count: 128)
                }
                if attributes == nil && cookie == .initial {
                    _ = packer.packEntry(
                        name: FSFileName(string: "."),
                        itemType: .directory,
                        itemID: directory.fileID,
                        nextCookie: FSDirectoryCookie(rawValue: UInt64(start)),
                        attributes: nil
                    )
                    _ = packer.packEntry(
                        name: FSFileName(string: ".."),
                        itemType: .directory,
                        itemID: directory.parentID,
                        nextCookie: FSDirectoryCookie(rawValue: UInt64(start)),
                        attributes: nil
                    )
                }
                for entry in page.entries {
                    start += 1
                    let childPath = self.join(directory.path, entry.name)
                    let child = try self.item(at: childPath, name: entry.name, parent: directory, hint: entry)
                    let attrs: FSItem.Attributes? = attributes.map { self.attributes(for: child, request: $0) }
                    let keepGoing = packer.packEntry(
                        name: FSFileName(string: entry.name),
                        itemType: child.itemType,
                        itemID: child.fileID,
                        nextCookie: FSDirectoryCookie(rawValue: UInt64(start)),
                        attributes: attrs
                    )
                    if !keepGoing { break }
                }
                _ = page.endOfDir
                reply(FSEnumerateDirectoryResult(verifier: currentVerifier.rawValue), nil)
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    // MARK: - Create / Remove / Rename

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        context: FSContext,
        replyHandler reply: @escaping (FSCreateItemResult?, (any Error)?) -> Void
    ) {
        guard let directory = directory as? AFPItem else {
            reply(nil, fs_error(.ENOTDIR, "Not a directory"))
            return
        }
        let childName = name.string ?? ""
        let path = join(directory.path, childName)
        queue.async {
            do {
                try self.ensureSession()
                switch type {
                case .directory:
                    try self.client.mkdir(path)
                    extensionTrace("mkdir OK \(path)")
                case .file:
                    try self.client.createFile(path)
                    extensionTrace("creat OK \(path)")
                default:
                    throw fs_error(.ENOTSUP, "Unsupported item type")
                }
                let item = try self.item(at: path, name: childName, parent: directory)
                let itemAttrs = self.attributes(for: item, request: FSCreateItemResult.requestedAttributes)
                let dirAttrs = self.attributes(for: directory, request: FSCreateItemResult.requestedAttributes)
                guard let result = FSCreateItemResult(
                    newItem: item,
                    newItemName: FSFileName(string: childName),
                    newItemAttributes: itemAttrs,
                    directoryAttributes: dirAttrs,
                    freeSpace: nil
                ) else {
                    extensionTrace("createItem FSCreateItemResult nil path=\(path)")
                    reply(nil, fs_error(.EIO, "FSCreateItemResult validation failed"))
                    return
                }
                reply(result, nil)
            } catch {
                let bridged = fs_bridge(error)
                extensionTrace("createItem FAIL \(path) errno=\(bridged.code) — \(bridged.localizedDescription)")
                reply(nil, bridged)
            }
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        in directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents: FSFileName,
        context: FSContext,
        replyHandler reply: @escaping (FSCreateSymlinkResult?, (any Error)?) -> Void
    ) {
        reply(nil, fs_error(.ENOTSUP, "AFP symlinks not supported in v1"))
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        in directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSCreateLinkResult?, (any Error)?) -> Void
    ) {
        reply(nil, fs_error(.ENOTSUP, "Hard links not supported"))
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        from directory: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSRemoveItemResult?, (any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem,
              let directory = directory as? AFPItem
        else {
            reply(nil, fs_error(.EINVAL, "Bad item"))
            return
        }
        queue.async {
            do {
                try self.ensureSession()
                // Force-close this item's AFP fork before unlink/rmdir.
                self.forceCloseOpenFork(item, reason: "removeItem")
                let itemAttrs = self.attributes(for: item, request: FSRemoveItemResult.requestedAttributes)
                do {
                    try self.removePath(item)
                } catch {
                    // One retry: close may race the server's FileBusy check.
                    let bridged = fs_bridge(error)
                    if bridged.code == EIO || bridged.code == EBUSY {
                        self.forceCloseOpenFork(item, reason: "removeItem/retry")
                        try self.removePath(item)
                    } else {
                        throw error
                    }
                }
                self.itemsByPath.removeValue(forKey: item.path)
                extensionTrace("removeItem OK \(item.path)")
                let dirAttrs = self.attributes(for: directory, request: FSRemoveItemResult.requestedAttributes)
                reply(FSRemoveItemResult(itemAttributes: itemAttrs, directoryAttributes: dirAttrs, freeSpace: nil), nil)
            } catch {
                let bridged = fs_bridge(error)
                extensionTrace("removeItem FAIL \(item.path) errno=\(bridged.code) — \(bridged.localizedDescription)")
                reply(nil, bridged)
            }
        }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        context: FSContext,
        replyHandler reply: @escaping (FSRenameItemResult?, (any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem,
              let sourceDirectory = sourceDirectory as? AFPItem,
              let destinationDirectory = destinationDirectory as? AFPItem
        else {
            reply(nil, fs_error(.EINVAL, "Bad item"))
            return
        }
        let newName = destinationName.string ?? ""
        let newPath = join(destinationDirectory.path, newName)
        queue.async {
            do {
                try self.ensureSession()
                let attrReq = FSRenameItemResult.requestedAttributes
                let surviving: AFPItem
                var overAttrs: FSItem.Attributes?

                if let over = overItem as? AFPItem {
                    if over.itemType == .directory || item.itemType == .directory {
                        throw fs_error(.EISDIR, "Replace-on-rename only supports files")
                    }
                    // Stock AFP cannot rename-over-existing. POSIX-style replace:
                    // unlink destination, then rename source (no FPExchangeFiles).
                    self.forceCloseOpenFork(item, reason: "renameOver/src")
                    self.forceCloseOpenFork(over, reason: "renameOver/dst")
                    overAttrs = self.attributes(for: over, request: attrReq)
                    try self.client.unlink(over.path)
                    self.itemsByPath.removeValue(forKey: over.path)
                    let oldPath = item.path
                    try self.client.rename(from: oldPath, to: newPath)
                    self.itemsByPath.removeValue(forKey: oldPath)
                    item.path = newPath
                    item.name = newName
                    item.parentID = destinationDirectory.fileID
                    self.itemsByPath[newPath] = item
                    surviving = item
                    extensionTrace("renameOver OK \(oldPath) → \(newPath) (unlink+rename)")
                } else {
                    // TextEdit safe-save renames the open document aside, then deletes
                    // it. Migrating openState still left intermittent FileBusy/EIO on
                    // that delete (server fork not always clear). Close before rename
                    // so the aside CNID is never busy; FSKit reopens via ensureOpen
                    // if it writes again (serialized on this queue).
                    let oldPath = item.path
                    let hadOpen = item.openState != nil
                    self.forceCloseOpenFork(item, reason: "rename/aside")
                    try self.client.rename(from: oldPath, to: newPath)
                    self.itemsByPath.removeValue(forKey: oldPath)
                    item.path = newPath
                    item.name = newName
                    item.parentID = destinationDirectory.fileID
                    self.itemsByPath[newPath] = item
                    surviving = item
                    extensionTrace(
                        "rename OK \(oldPath) → \(newPath) closedBeforeRename=\(hadOpen)"
                    )
                }

                reply(
                    FSRenameItemResult(
                        newName: FSFileName(string: newName),
                        renamedItemAttributes: self.attributes(for: surviving, request: attrReq),
                        sourceDirectoryAttributes: self.attributes(for: sourceDirectory, request: attrReq),
                        destinationDirectoryAttributes: self.attributes(for: destinationDirectory, request: attrReq),
                        overItemAttributes: overAttrs,
                        freeSpace: nil
                    ),
                    nil
                )
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    func readSymbolicLink(
        _ item: FSItem,
        context: FSContext,
        replyHandler reply: @escaping (FSReadSymlinkResult?, (any Error)?) -> Void
    ) {
        reply(nil, fs_error(.EINVAL, "Not a symlink"))
    }

    // MARK: - Open / Read / Write

    func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        context: FSContext,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem else {
            reply(fs_error(.EINVAL, "Bad item"))
            return
        }
        if item.itemType == .directory {
            reply(nil)
            return
        }
        queue.async {
            do {
                try self.ensureSession()
                let writeable = modes.contains(.write)
                _ = try self.ensureOpen(item, writeable: writeable)
                reply(nil)
            } catch {
                reply(fs_bridge(error))
            }
        }
    }

    func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        context: FSContext,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem else {
            reply(fs_error(.EINVAL, "Bad item"))
            return
        }
        queue.async {
            self.releaseOpen(item)
            reply(nil)
        }
    }

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (FSReadFileResult?, (any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem else {
            reply(nil, fs_error(.EINVAL, "Bad item"))
            return
        }
        queue.async {
            do {
                let written = try self.withIdempotentSessionRetry { () -> Int in
                    let fileID = try self.ensureOpen(item, writeable: false)
                    defer { self.releaseOpen(item) }
                    let (data, _) = try self.client.read(
                        .init(fileID: fileID),
                        offset: UInt64(offset),
                        length: UInt32(length)
                    )
                    return buffer.withUnsafeMutableBytes { dest in
                        data.copyBytes(to: dest.bindMemory(to: UInt8.self), count: min(data.count, length))
                        return min(data.count, length)
                    }
                }
                let attrs = self.attributes(for: item, request: FSReadFileResult.requestedAttributes)
                reply(FSReadFileResult(bytesRead: written, itemAttributes: attrs), nil)
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping (FSWriteFileResult?, (any Error)?) -> Void
    ) {
        guard let item = item as? AFPItem else {
            reply(nil, fs_error(.EINVAL, "Bad item"))
            return
        }
        queue.async {
            do {
                // Non-idempotent — reconnect once only if we were not attached; never replay write.
                try self.ensureSession()
                let fileID = try self.ensureOpen(item, writeable: true)
                defer { self.releaseOpen(item) }
                let written = try self.client.write(.init(fileID: fileID), offset: UInt64(offset), data: contents)
                item.size = max(item.size, UInt64(offset) + UInt64(written))
                let attrs = self.attributes(for: item, request: FSWriteFileResult.requestedAttributes)
                reply(FSWriteFileResult(bytesWritten: written, itemAttributes: attrs, freeSpace: nil), nil)
            } catch let error as AFPError where error.isSessionStale {
                self.invalidateSessionLocked()
                reply(nil, fs_bridge(error))
            } catch {
                reply(nil, fs_bridge(error))
            }
        }
    }

    // MARK: - Helpers

    private func ensureSession() throws {
        if !client.isAttached {
            var session = components
            session.password = "" // never trust URL passwords under FSKit
            var loggedIn = false

            // Appex reaches afpsld via host TCP→Unix proxy (Unix /tmp connect is EPERM).
            let socketPath = AFPIPC.socketPath
            setenv("AFPSL_SOCKET_PATH", socketPath, 1)
            setenv("AFPSL_TCP_PORT", AFPIPC.tcpProxyPortEnv, 1)
            let socketExists = FileManager.default.fileExists(atPath: socketPath)
            extensionTrace(
                "session uid=\(getuid()) euid=\(geteuid()) socket=\(socketPath) exists=\(socketExists) tcpPort=\(AFPIPC.tcpProxyPort) user=\(session.username) host=\(session.host) port=\(session.port) vol=\(session.volume)"
            )
            // Socket existence is informational — IPC uses 127.0.0.1:AFPSL_TCP_PORT.

            // Opportunistic resume only — host no longer primes a session.
            do {
                try client.resume(to: session)
                log.info("Resumed existing afpsld session for \(session.host, privacy: .public)")
                extensionTrace("resume OK host=\(session.host) user=\(session.username)")
                loggedIn = true
            } catch let error as AFPError {
                let errno = error.rawErrno.map(String.init) ?? "-"
                extensionTrace(
                    "resume miss op=\(error.operationName) errno=\(errno) — \(error.localizedDescription)"
                )
                log.info("No resumable session; keychain login next")
            } catch {
                let ns = error as NSError
                extensionTrace(
                    "resume miss domain=\(ns.domain) code=\(ns.code) — \(error.localizedDescription)"
                )
            }

            if !loggedIn {
                let isGuest = session.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isGuest {
                    extensionTrace("guest connect (No User Authent) host=\(session.host)")
                    session.password = ""
                    do {
                        try client.connect(to: session, guest: true)
                        extensionTrace("guest connect OK")
                        loggedIn = true
                    } catch let error as AFPError where error.isRetryable {
                        extensionTrace("guest connect transient fail: \(error); retrying once")
                        Thread.sleep(forTimeInterval: 0.5)
                        do {
                            try client.connect(to: session, guest: true)
                            extensionTrace("guest connect retry OK")
                            loggedIn = true
                        } catch {
                            extensionTrace("guest connect retry failed: \(error)")
                            throw error
                        }
                    } catch {
                        extensionTrace("guest connect failed (no retry): \(error)")
                        throw error
                    }
                } else {
                    let status = KeychainStore.passwordStatus(
                        account: session.username,
                        server: session.host,
                        port: session.port
                    )
                    let statusText = KeychainStore.describeStatus(status)
                    extensionTrace(
                        "keychain lookup \(session.username)@\(session.host):\(session.port) \(statusText) group=\(KeychainStore.accessGroup)"
                    )
                    guard let stored = KeychainStore.password(
                        account: session.username,
                        server: session.host,
                        port: session.port
                    ), !stored.isEmpty else {
                        log.error(
                            "No keychain password for \(session.username, privacy: .public)@\(session.host, privacy: .public) (\(statusText, privacy: .public))"
                        )
                        extensionTrace("keychain miss — aborting (\(statusText))")
                        throw AFPError.credentialsUnavailable(status: status)
                    }
                    if stored.utf8.count > AFPClient.maxPasswordUTF8Bytes {
                        extensionTrace("keychain password too long passLen=\(stored.utf8.count)")
                        throw AFPError.passwordTooLong
                    }
                    session.password = stored
                    do {
                        try client.connect(to: session)
                        extensionTrace("keychain connect OK passLen=\(stored.utf8.count)")
                        loggedIn = true
                    } catch let error as AFPError where error.isRetryable {
                        extensionTrace(
                            "keychain connect transient fail passLen=\(stored.utf8.count): \(error); retrying once"
                        )
                        Thread.sleep(forTimeInterval: 0.5)
                        do {
                            try client.connect(to: session)
                            extensionTrace("keychain connect retry OK")
                            loggedIn = true
                        } catch {
                            extensionTrace("keychain connect retry failed: \(error)")
                            throw error
                        }
                    } catch {
                        extensionTrace("keychain connect failed (no retry): \(error)")
                        throw error
                    }
                }
            }

            do {
                try client.attach(volumeName: session.volume)
                // afp_shim_attach treats ALREADY_ATTACHED as success (rc=0).
                log.info("AFP volume attached")
                extensionTrace("attach OK vol=\(session.volume)")
            } catch {
                log.error("AFP attach failed: \(String(describing: error), privacy: .public)")
                if let afp = error as? AFPError {
                    extensionTrace(
                        "attach failed op=\(afp.operationName) errno=\(afp.rawErrno.map(String.init) ?? "-") — \(afp.localizedDescription)"
                    )
                } else {
                    extensionTrace("attach failed: \(error)")
                }
                throw error
            }
        }
    }

    private func ensureOpen(_ item: AFPItem, writeable: Bool) throws -> UInt32 {
        if var state = item.openState {
            if !writeable || state.writable {
                state.refCount += 1
                item.openState = state
                return state.fileID
            }
            // Upgrade read-only fork to writable.
            try? client.close(.init(fileID: state.fileID))
            let file = try client.open(path: item.path, writeable: true)
            item.openState = AFPItem.OpenState(
                fileID: file.fileID,
                writable: true,
                refCount: state.refCount + 1
            )
            return file.fileID
        }
        let file = try client.open(path: item.path, writeable: writeable)
        item.openState = AFPItem.OpenState(fileID: file.fileID, writable: writeable, refCount: 1)
        return file.fileID
    }

    private func releaseOpen(_ item: AFPItem) {
        guard var state = item.openState else { return }
        state.refCount -= 1
        if state.refCount <= 0 {
            try? client.close(.init(fileID: state.fileID))
            item.openState = nil
        } else {
            item.openState = state
        }
    }

    private func item(
        at path: String,
        name: String,
        parent: AFPItem,
        hint: AFPClient.DirectoryEntry? = nil
    ) throws -> AFPItem {
        if let cached = itemsByPath[path] {
            return cached
        }
        let st: Darwin.stat
        if let hint {
            var fake = Darwin.stat()
            fake.st_mode = hint.mode | (hint.isDirectory ? S_IFDIR : S_IFREG)
            fake.st_size = off_t(hint.size)
            fake.st_mtimespec = timespec(tv_sec: Int(hint.modificationDate.timeIntervalSince1970), tv_nsec: 0)
            st = fake
        } else {
            st = try client.stat(path)
        }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let id = FSItem.Identifier(rawValue: nextID) ?? .invalid
        nextID += 1
        let item = AFPItem(
            path: path,
            name: name,
            itemType: isDir ? .directory : .file,
            fileID: id,
            parentID: parent.fileID,
            size: UInt64(max(0, st.st_size)),
            mode: st.st_mode,
            mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        )
        itemsByPath[path] = item
        return item
    }

    private func attributes(for item: AFPItem, request: FSItem.GetAttributesRequest) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        if request.isAttributeWanted(.type) { attrs.type = item.itemType }
        if request.isAttributeWanted(.mode) { attrs.mode = UInt32(item.mode & 0o7777) }
        if request.isAttributeWanted(.size) { attrs.size = item.size }
        if request.isAttributeWanted(.allocSize) { attrs.allocSize = item.size }
        if request.isAttributeWanted(.fileID) { attrs.fileID = item.fileID }
        if request.isAttributeWanted(.parentID) { attrs.parentID = item.parentID }
        if request.isAttributeWanted(.linkCount) { attrs.linkCount = 1 }
        if request.isAttributeWanted(.uid) { attrs.uid = getuid() }
        if request.isAttributeWanted(.gid) { attrs.gid = getgid() }
        let ts = timespec(tv_sec: Int(item.mtime.timeIntervalSince1970), tv_nsec: 0)
        if request.isAttributeWanted(.modifyTime) { attrs.modifyTime = ts }
        if request.isAttributeWanted(.changeTime) { attrs.changeTime = ts }
        if request.isAttributeWanted(.accessTime) { attrs.accessTime = ts }
        if request.isAttributeWanted(.birthTime) { attrs.birthTime = ts }
        if request.isAttributeWanted(.addedTime) { attrs.addedTime = ts }
        if request.isAttributeWanted(.backupTime) { attrs.backupTime = ts }
        if request.isAttributeWanted(.flags) { attrs.flags = 0 }
        if request.isAttributeWanted(.supportsLimitedXAttrs) { attrs.supportsLimitedXAttrs = true }
        if request.isAttributeWanted(.inhibitKernelOffloadedIO) { attrs.inhibitKernelOffloadedIO = true }
        return attrs
    }

    private func join(_ parent: String, _ name: String) -> String {
        if parent == "/" { return "/\(name)" }
        return "\(parent)/\(name)"
    }
}

private func extensionTrace(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/classic548-extension.log")
    if FileManager.default.fileExists(atPath: url.path) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    } else {
        try? data.write(to: url, options: .atomic)
    }
}
