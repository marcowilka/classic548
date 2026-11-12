import Foundation

/// Shared IPC paths for `afpsld` ↔ `libafpsl`.
///
/// `afpsld` binds a Unix socket under `/tmp` (works for the unsandboxed host helper).
/// The sandboxed FSKit appex cannot `connect()` to that Unix socket (EPERM even with a
/// `/tmp` temporary-exception), so the host also runs a loopback TCP proxy and the
/// appex reaches afpsld via `AFPSL_TCP_PORT` → `127.0.0.1`.
public enum AFPIPC {
    public static let socketFileName = "classic548-afpsl"
    public static let defaultSocketPath = "/tmp/\(socketFileName)"

    /// Fixed loopback port for host TCP→Unix proxy (appex has `network.client`).
    public static let tcpProxyPort: UInt16 = 18548

    public static let appGroupID = "group.de.marcowilka.classic548"

    public static var socketPath: String {
        if let env = ProcessInfo.processInfo.environment["AFPSL_SOCKET_PATH"], !env.isEmpty {
            return env
        }
        return defaultSocketPath
    }

    public static var tcpProxyPortEnv: String {
        String(tcpProxyPort)
    }

    /// Ensure the socket directory exists and return the Unix path for afpsld launch.
    @discardableResult
    public static func prepareContainer() throws -> String {
        let path = socketPath
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return path
    }
}
