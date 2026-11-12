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
        try? client.detach()
        try? client.disconnect()
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
                reply(nil, error)
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
                reply(nil, error)
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
                reply(nil, error)
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
                reply(nil, error)
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
                try self.ensureSession()
                var start = Int(cookie.rawValue)
                let currentVerifier: FSDirectoryVerifier = verifier == .initial
                    ? FSDirectoryVerifier(rawValue: UInt64(Date().timeIntervalSince1970))
                    : verifier
                let page = try self.client.readDirectory(directory.path, start: start, count: 128)
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
                reply(nil, error)
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
                case .file:
                    try self.client.createFile(path)
                default:
                    throw fs_error(.ENOTSUP, "Unsupported item type")
                }
                let item = try self.item(at: path, name: childName, parent: directory)
                let itemAttrs = self.attributes(for: item, request: FSCreateItemResult.requestedAttributes)
                let dirAttrs = self.attributes(for: directory, request: FSCreateItemResult.requestedAttributes)
                reply(
                    FSCreateItemResult(
                        newItem: item,
                        newItemName: FSFileName(string: childName),
                        newItemAttributes: itemAttrs,
                        directoryAttributes: dirAttrs,
                        freeSpace: nil
                    ),
                    nil
                )
            } catch {
                reply(nil, error)
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
                let itemAttrs = self.attributes(for: item, request: FSRemoveItemResult.requestedAttributes)
                if item.itemType == .directory {
                    try self.client.rmdir(item.path)
                } else {
                    try self.client.unlink(item.path)
                }
                let dirAttrs = self.attributes(for: directory, request: FSRemoveItemResult.requestedAttributes)
                reply(FSRemoveItemResult(itemAttributes: itemAttrs, directoryAttributes: dirAttrs, freeSpace: nil), nil)
            } catch {
                reply(nil, error)
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
                // Do not delete-then-rename: a failed rename would lose the destination.
                // AFP replace-on-rename is not guaranteed; refuse overwrite instead.
                if overItem != nil {
                    throw fs_error(.EEXIST, "Replace-on-rename is not supported safely over AFP")
                }
                try self.client.rename(from: item.path, to: newPath)
                self.itemsByPath.removeValue(forKey: item.path)
                let renamed = try self.item(at: newPath, name: newName, parent: destinationDirectory)
                reply(
                    FSRenameItemResult(
                        newName: FSFileName(string: newName),
                        renamedItemAttributes: self.attributes(for: renamed, request: FSRenameItemResult.requestedAttributes),
                        sourceDirectoryAttributes: self.attributes(for: sourceDirectory, request: FSRenameItemResult.requestedAttributes),
                        destinationDirectoryAttributes: self.attributes(for: destinationDirectory, request: FSRenameItemResult.requestedAttributes),
                        overItemAttributes: nil,
                        freeSpace: nil
                    ),
                    nil
                )
            } catch {
                reply(nil, error)
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
                let file = try self.client.open(path: item.path, writeable: writeable)
                item.openFileID = file.fileID
                reply(nil)
            } catch {
                reply(error)
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
            if let fileID = item.openFileID {
                try? self.client.close(.init(fileID: fileID))
                item.openFileID = nil
            }
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
                try self.ensureSession()
                let fileID = try self.ensureOpen(item, writeable: false)
                let (data, _) = try self.client.read(.init(fileID: fileID), offset: UInt64(offset), length: UInt32(length))
                let written = buffer.withUnsafeMutableBytes { dest in
                    data.copyBytes(to: dest.bindMemory(to: UInt8.self), count: min(data.count, length))
                    return min(data.count, length)
                }
                let attrs = self.attributes(for: item, request: FSReadFileResult.requestedAttributes)
                reply(FSReadFileResult(bytesRead: written, itemAttributes: attrs), nil)
            } catch {
                reply(nil, error)
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
                try self.ensureSession()
                let fileID = try self.ensureOpen(item, writeable: true)
                let written = try self.client.write(.init(fileID: fileID), offset: UInt64(offset), data: contents)
                item.size = max(item.size, UInt64(offset) + UInt64(written))
                let attrs = self.attributes(for: item, request: FSWriteFileResult.requestedAttributes)
                reply(FSWriteFileResult(bytesWritten: written, itemAttributes: attrs, freeSpace: nil), nil)
            } catch {
                reply(nil, error)
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
        if let existing = item.openFileID {
            return existing
        }
        let file = try client.open(path: item.path, writeable: writeable)
        item.openFileID = file.fileID
        return file.fileID
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
