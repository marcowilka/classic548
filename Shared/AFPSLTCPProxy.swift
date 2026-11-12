import Foundation

/// Accepts TCP connections on loopback and relays bytes to the local afpsld Unix socket.
/// Lets the sandboxed FSKit appex talk to afpsld without Unix-domain `connect()` (EPERM).
public final class AFPSLTCPProxy {
    public static let shared = AFPSLTCPProxy()

    private let lock = NSLock()
    private var acceptSource: DispatchSourceRead?
    private var running = false

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func ensureRunning(unixSocketPath: String, port: UInt16 = AFPIPC.tcpProxyPort) throws {
        lock.lock(); defer { lock.unlock() }
        if running { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ProxyError.socketCreate(errno)
        }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            let e = errno
            close(fd)
            throw ProxyError.bind(e)
        }
        guard listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            throw ProxyError.listen(e)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        let path = unixSocketPath
        source.setEventHandler { [weak self] in
            self?.acceptOne(listenFD: fd, unixSocketPath: path)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        acceptSource = source
        running = true
        DiagnosticsLog.shared.info(
            "afpsld TCP proxy listening on 127.0.0.1:\(port) → \(unixSocketPath)"
        )
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        acceptSource?.cancel()
        acceptSource = nil
        running = false
    }

    private func acceptOne(listenFD: Int32, unixSocketPath: String) {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listenFD, $0, &len)
            }
        }
        guard client >= 0 else { return }

        let unix = Self.connectUnix(unixSocketPath)
        guard unix >= 0 else {
            close(client)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            Self.bridge(client: client, unix: unix)
        }
    }

    private static func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout.size(ofValue: on)))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            bytes.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let pathByteCount = path.utf8.count + 1
        let addrLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathByteCount)
        addr.sun_len = UInt8(min(Int(addrLen), Int(UInt8.max)))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        if rc != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private static func bridge(client: Int32, unix: Int32) {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(from: client, to: unix)
            shutdown(unix, SHUT_WR)
            shutdown(client, SHUT_RD)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            pump(from: unix, to: client)
            shutdown(client, SHUT_WR)
            shutdown(unix, SHUT_RD)
            group.leave()
        }
        group.wait()
        close(client)
        close(unix)
    }

    private static func pump(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &buffer, buffer.count)
            if n <= 0 { return }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return write(to, base.advanced(by: written), n - written)
                }
                if w <= 0 { return }
                written += w
            }
        }
    }

    public enum ProxyError: Error, LocalizedError {
        case socketCreate(Int32)
        case bind(Int32)
        case listen(Int32)

        public var errorDescription: String? {
            switch self {
            case .socketCreate(let e):
                return "TCP proxy socket() failed (errno \(e))"
            case .bind(let e):
                return "TCP proxy bind() failed (errno \(e)) — is another ClassicAFP running?"
            case .listen(let e):
                return "TCP proxy listen() failed (errno \(e))"
            }
        }
    }
}
