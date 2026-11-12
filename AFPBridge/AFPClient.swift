import Foundation

/// Thread-safe wrapper around Netatalk Client via `AFPShim` (IPC to `afpsld`).
/// C API comes from `AFPBridge-Bridging-Header.h`.
public final class AFPClient: @unchecked Sendable {
    public struct DirectoryEntry: Sendable {
        public let name: String
        public let size: UInt64
        public let isDirectory: Bool
        public let modificationDate: Date
        public let mode: mode_t
    }

    public struct OpenFile: Sendable {
        public let fileID: UInt32
        public init(fileID: UInt32) { self.fileID = fileID }
    }

    private let lock = NSLock()
    private var server: AFPServerHandle?
    private var volume: AFPVolumeHandle?
    private var connectedURL = AFPURLComponents(host: "", volume: "")

    public init() {}

    deinit {
        try? detach()
        try? disconnect()
    }

    /// Shim password field is 128 bytes including NUL.
    public static let maxPasswordUTF8Bytes = 127

    public var isAttached: Bool {
        lock.lock(); defer { lock.unlock() }
        return volume != nil
    }

    public func connect(to components: AFPURLComponents) throws {
        lock.lock(); defer { lock.unlock() }
        try Self.validatePasswordLength(components.password)
        var handle: AFPServerHandle?
        let url = makeShimURL(components)
        let rc = withUnsafePointer(to: url) { afp_shim_connect($0, afp_shim_default_uams(), &handle) }
        if rc != 0 {
            throw AFPError.loginFromErrno(rc)
        }
        server = handle
        connectedURL = components
    }

    public func resume(to components: AFPURLComponents) throws {
        lock.lock(); defer { lock.unlock() }
        var handle: AFPServerHandle?
        // Resume must be password-less — clear any leftover before IPC.
        var resumeComponents = components
        resumeComponents.password = ""
        let url = makeShimURL(resumeComponents)
        let rc = withUnsafePointer(to: url) { afp_shim_resume($0, afp_shim_default_uams(), &handle) }
        if rc != 0 {
            throw AFPError.resumeFromErrno(rc)
        }
        server = handle
        connectedURL = resumeComponents
    }

    public func disconnect() throws {
        lock.lock(); defer { lock.unlock() }
        guard server != nil else { return }
        var handle = server
        let rc = afp_shim_disconnect(&handle)
        server = nil
        volume = nil
        try throwIfNeeded(rc)
    }

    public func attach(volumeName: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let server else { throw AFPError.notConnected }
        var components = connectedURL
        if let volumeName { components.volume = volumeName }
        var volumeHandle: AFPVolumeHandle?
        var needsPassword: Int32 = 0
        let url = makeShimURL(components)
        let rc = withUnsafePointer(to: url) {
            afp_shim_attach(server, $0, &volumeHandle, &needsPassword)
        }
        if rc != 0 {
            if needsPassword != 0 { throw AFPError.attachRequiresPassword }
            throw AFPError.attachFromErrno(rc)
        }
        volume = volumeHandle
        connectedURL = components
    }

    public func detach() throws {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { return }
        var handle = volume
        let url = makeShimURL(connectedURL)
        let rc = withUnsafePointer(to: url) { afp_shim_detach(&handle, $0) }
        volume = nil
        try throwIfNeeded(rc)
    }

    public func listVolumes() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let server else { throw AFPError.notConnected }
        var buffer = [CChar](repeating: 0, count: 16 * 256)
        var count: UInt32 = 0
        let url = makeShimURL(connectedURL)
        let rc = withUnsafePointer(to: url) {
            afp_shim_list_volumes(server, $0, &buffer, buffer.count, &count)
        }
        try throwIfNeeded(rc)
        var names: [String] = []
        var index = 0
        while names.count < Int(count) && index < buffer.count {
            let name = buffer.withUnsafeBufferPointer { ptr in
                String(cString: ptr.baseAddress! + index)
            }
            if name.isEmpty { break }
            names.append(name)
            index += name.utf8.count + 1
        }
        return names
    }

    public func stat(_ path: String) throws -> stat {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        var st = Darwin.stat()
        let url = makeShimURL(connectedURL)
        let rc = path.withCString { pathC in
            withUnsafePointer(to: url) { afp_shim_stat(&handle, pathC, $0, &st) }
        }
        try throwIfNeeded(rc)
        volume = handle
        return st
    }

    public func readDirectory(_ path: String, start: Int = 0, count: Int = 256) throws -> (entries: [DirectoryEntry], endOfDir: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        var entriesBuffer = [AFPShimDirEntry](repeating: AFPShimDirEntry(), count: count)
        var outCount: UInt32 = 0
        var eod: Int32 = 0
        let url = makeShimURL(connectedURL)
        let rc = path.withCString { pathC in
            withUnsafePointer(to: url) {
                afp_shim_readdir(&handle, pathC, $0, Int32(start), Int32(count), &entriesBuffer, &outCount, &eod)
            }
        }
        try throwIfNeeded(rc)
        volume = handle

        let entries: [DirectoryEntry] = entriesBuffer.prefix(Int(outCount)).map { entry in
            let name = withUnsafePointer(to: entry.name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            let mode = mode_t(entry.mode)
            let isDir = entry.is_directory != 0 || (mode & S_IFMT) == S_IFDIR
            return DirectoryEntry(
                name: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                size: entry.size,
                isDirectory: isDir,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(entry.mtime)),
                mode: mode == 0 ? (isDir ? 0o755 : 0o644) : mode
            )
        }
        return (entries, eod != 0)
    }

    public func open(path: String, writeable: Bool) throws -> OpenFile {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        var fileID: UInt32 = 0
        let url = makeShimURL(connectedURL)
        let mode: UInt32 = writeable ? 2 : 0
        let rc = path.withCString { pathC in
            withUnsafePointer(to: url) { afp_shim_open(&handle, pathC, $0, mode, &fileID) }
        }
        try throwIfNeeded(rc)
        volume = handle
        return OpenFile(fileID: fileID)
    }

    public func close(_ file: OpenFile) throws {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        let rc = afp_shim_close(&handle, file.fileID)
        volume = handle
        try throwIfNeeded(rc)
    }

    public func read(_ file: OpenFile, offset: UInt64, length: UInt32) throws -> (Data, eof: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        var buffer = [CChar](repeating: 0, count: Int(length))
        var received: UInt32 = 0
        var eof: UInt32 = 0
        let rc = afp_shim_read(&handle, file.fileID, offset, length, &buffer, &received, &eof)
        volume = handle
        try throwIfNeeded(rc)
        let data = Data(bytes: buffer, count: Int(received))
        return (data, eof != 0)
    }

    public func write(_ file: OpenFile, offset: UInt64, data: Data) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        var written: UInt32 = 0
        let rc = data.withUnsafeBytes { raw in
            afp_shim_write(
                &handle,
                file.fileID,
                offset,
                raw.bindMemory(to: CChar.self).baseAddress,
                UInt32(data.count),
                &written
            )
        }
        volume = handle
        try throwIfNeeded(rc)
        return Int(written)
    }

    public func createFile(_ path: String, mode: mode_t = 0o644) throws {
        try pathOp(path) { handle, pathC, url in afp_shim_creat(&handle, pathC, url, mode) }
    }

    public func mkdir(_ path: String, mode: mode_t = 0o755) throws {
        try pathOp(path) { handle, pathC, url in afp_shim_mkdir(&handle, pathC, url, mode) }
    }

    public func unlink(_ path: String) throws {
        try pathOp(path) { handle, pathC, url in afp_shim_unlink(&handle, pathC, url) }
    }

    public func rmdir(_ path: String) throws {
        try pathOp(path) { handle, pathC, url in afp_shim_rmdir(&handle, pathC, url) }
    }

    public func rename(from: String, to: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        let url = makeShimURL(connectedURL)
        let rc = from.withCString { fromC in
            to.withCString { toC in
                withUnsafePointer(to: url) { afp_shim_rename(&handle, fromC, toC, $0) }
            }
        }
        volume = handle
        try throwIfNeeded(rc)
    }

    public func truncate(_ path: String, size: UInt64) throws {
        try pathOp(path) { handle, pathC, url in afp_shim_truncate(&handle, pathC, url, size) }
    }

    public func chmod(_ path: String, mode: mode_t) throws {
        try pathOp(path) { handle, pathC, url in afp_shim_chmod(&handle, pathC, url, mode) }
    }

    public func statfs(_ path: String = "/") throws -> statvfs {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        var st = Darwin.statvfs()
        let url = makeShimURL(connectedURL)
        let rc = path.withCString { pathC in
            withUnsafePointer(to: url) { afp_shim_statfs(&handle, pathC, $0, &st) }
        }
        volume = handle
        try throwIfNeeded(rc)
        return st
    }

    public static func exitDaemon() {
        _ = afp_shim_exit()
    }

    private func pathOp(_ path: String, _ body: (inout AFPVolumeHandle?, UnsafePointer<CChar>, UnsafePointer<AFPShimURL>) -> Int32) throws {
        lock.lock(); defer { lock.unlock() }
        guard volume != nil else { throw AFPError.notConnected }
        var handle = volume
        let url = makeShimURL(connectedURL)
        let rc = path.withCString { pathC in
            withUnsafePointer(to: url) { body(&handle, pathC, $0) }
        }
        volume = handle
        try throwIfNeeded(rc)
    }

    private func makeShimURL(_ components: AFPURLComponents) -> AFPShimURL {
        var url = AFPShimURL()
        url.port = Int32(components.port)
        assign(&url.username.0, components.username, 128)
        assign(&url.password.0, components.password, 128)
        assign(&url.servername.0, components.host, 256)
        assign(&url.volumename.0, components.volume, 256)
        assign(&url.path.0, components.path, 1024)
        return url
    }

    private static func validatePasswordLength(_ password: String) throws {
        if password.utf8.count > maxPasswordUTF8Bytes {
            throw AFPError.passwordTooLong
        }
    }

    private func assign(_ dest: UnsafeMutablePointer<CChar>, _ value: String, _ max: Int) {
        memset(dest, 0, max)
        value.withCString { src in
            strncpy(dest, src, max - 1)
            dest[max - 1] = 0
        }
    }

    private func throwIfNeeded(_ rc: Int32) throws {
        if rc != 0 {
            throw AFPError.fromErrno(rc)
        }
    }
}
