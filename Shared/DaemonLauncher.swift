import AFPBridge
import Foundation

/// Starts and supervises the bundled `afpsld` helper (GPL Netatalk Client daemon).
public final class DaemonLauncher {
    public static let shared = DaemonLauncher()

    private var process: Process?
    /// True when we reused an orphan daemon (no Process handle) this session.
    private var adoptedLiveSocket = false
    private let lock = NSLock()

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { return true }
        if adoptedLiveSocket, Self.isSocketAccepting(AFPIPC.socketPath, attempts: 2) {
            return true
        }
        return Self.isSocketAccepting(AFPIPC.socketPath, attempts: 1)
    }

    @discardableResult
    public func ensureRunning() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning {
            try ensureProxyLocked(socketPath: AFPIPC.socketPath)
            return true
        }
        self.process = nil

        let socketPath = try AFPIPC.prepareContainer()

        // Reuse a live daemon. Probe with retries — Darwin AF_UNIX connect can
        // spuriously fail when sun_len is wrong / under load; that used to make
        // us unlink a live socket and break an active /Volumes mount.
        if Self.isSocketAccepting(socketPath, attempts: 5) {
            adoptedLiveSocket = true
            DiagnosticsLog.shared.info("afpsld already accepting at \(socketPath)")
            try ensureProxyLocked(socketPath: socketPath)
            return true
        }

        // Only unlink when the node exists and repeated connects fail.
        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.isSocketAccepting(socketPath, attempts: 3) {
                adoptedLiveSocket = true
                DiagnosticsLog.shared.info("afpsld became ready at \(socketPath)")
                try ensureProxyLocked(socketPath: socketPath)
                return true
            }
            DiagnosticsLog.shared.info("Removing stale afpsld socket \(socketPath)")
            try? FileManager.default.removeItem(atPath: socketPath)
            adoptedLiveSocket = false
        }

        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let url = helpers.appendingPathComponent("afpsld")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DaemonError.helperMissing
        }

        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = url
        process.arguments = ["-f", "--logmethod", "stdout", "--loglevel", "LOG_NOTICE"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "DYLD_LIBRARY_PATH": helpers.path,
            "AFPSL_SOCKET_PATH": socketPath
        ]) { _, new in new }
        process.standardOutput = stderrPipe
        process.standardError = stderrPipe
        try process.run()
        self.process = process
        adoptedLiveSocket = false

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if !process.isRunning {
                self.process = nil
                let detail = Self.readPipe(stderrPipe)
                DiagnosticsLog.shared.error(
                    detail.isEmpty
                        ? "afpsld exited before socket was ready"
                        : "afpsld exited before socket was ready — \(detail)"
                )
                throw DaemonError.startFailed
            }
            if Self.isSocketAccepting(socketPath, attempts: 1) {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let running = process.isRunning && Self.isSocketAccepting(socketPath, attempts: 3)
        DiagnosticsLog.shared.info(
            running
                ? "afpsld launched (pid \(process.processIdentifier)) socket=\(socketPath)"
                : "afpsld failed to stay running / accept on \(socketPath)"
        )
        if !running {
            process.terminate()
            process.waitUntilExit()
            let detail = Self.readPipe(stderrPipe)
            if !detail.isEmpty {
                DiagnosticsLog.shared.error("afpsld stderr: \(detail)")
            }
            self.process = nil
            throw DaemonError.startFailed
        }

        try ensureProxyLocked(socketPath: socketPath)
        return true
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        AFPSLTCPProxy.shared.stop()
        // Only terminate the process we started — never kill foreign afpsld.
        if let process, process.isRunning {
            process.terminate()
            DiagnosticsLog.shared.info("afpsld stopped (pid \(process.processIdentifier))")
        }
        process = nil
        adoptedLiveSocket = false
        AFPClient.exitDaemon()
    }

    private func ensureProxyLocked(socketPath: String) throws {
        do {
            try AFPSLTCPProxy.shared.ensureRunning(unixSocketPath: socketPath)
        } catch {
            DiagnosticsLog.shared.error("afpsld TCP proxy failed: \(error.localizedDescription)")
            throw DaemonError.startFailed
        }
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return "" }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    /// Probe whether something is accepting connections on our Unix socket.
    private static func isSocketAccepting(_ path: String, attempts: Int) -> Bool {
        for i in 0..<max(1, attempts) {
            if connectUnixOnce(path) {
                return true
            }
            if i + 1 < attempts {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return false
    }

    private static func connectUnixOnce(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        // sun_path capacity on Darwin is typically 104.
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            pathBytes.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        // Darwin requires sun_len; sizeof(sockaddr_un) is wrong for abstract/short paths
        // and used to make connect() fail intermittently → false "stale socket" kills.
        let pathByteCount = path.utf8.count + 1 // include NUL
        let addrLen = socklen_t(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathByteCount)
        addr.sun_len = UInt8(min(Int(addrLen), Int(UInt8.max)))

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, addrLen)
            }
        }
        return rc == 0
    }

    public enum DaemonError: Error, LocalizedError {
        case helperMissing
        case startFailed

        public var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "Bundled afpsld helper was not found in the app bundle."
            case .startFailed:
                return "afpsld exited immediately after launch — check Helpers signing / dylibs / socket path."
            }
        }
    }
}
