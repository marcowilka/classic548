import Foundation

public enum AFPError: Error, LocalizedError, CustomNSError, Sendable {
    case posix(Int32)
    case invalidURL
    case notConnected
    case daemonUnavailable
    case attachRequiresPassword
    /// Keychain miss / unreadable before any AFP login was attempted.
    case credentialsUnavailable(status: OSStatus)
    /// NAS rejected login during `connect` (after credentials were available).
    case loginFailed(errno: Int32)
    /// `afp_sl_resume` could not reclaim a live session (usually ENOTCONN).
    case resumeFailed(errno: Int32)
    /// Volume attach failed after an authenticated session exists.
    case attachFailed(errno: Int32)
    case passwordTooLong
    case unexpected(String)

    public static var errorDomain: String { "AFPBridge.AFPError" }

    public var errorCode: Int {
        switch self {
        case .posix(let code):
            return Int(Self.absErrno(code))
        case .invalidURL:
            return 1001
        case .notConnected:
            return 1002
        case .daemonUnavailable:
            return 1003
        case .attachRequiresPassword:
            return 1004
        case .loginFailed:
            return 1005
        case .credentialsUnavailable:
            return 1008
        case .resumeFailed(let errno):
            return 1100 + Int(Self.absErrno(errno))
        case .attachFailed(let errno):
            return 1200 + Int(Self.absErrno(errno))
        case .passwordTooLong:
            return 1007
        case .unexpected:
            return 1006
        }
    }

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "AFP error"]
        if let errno = rawErrno {
            info["AFPErrno"] = errno
        }
        if case .credentialsUnavailable(let status) = self {
            info["KeychainStatus"] = status
        }
        info["AFPOperation"] = operationName
        return info
    }

    public var errorDescription: String? {
        switch self {
        case .posix(let code):
            let errnoCode = Self.absErrno(code)
            return "AFP/POSIX \(errnoCode): \(String(cString: strerror(errnoCode)))"
        case .invalidURL:
            return "Invalid AFP URL"
        case .notConnected:
            return "Not connected to AFP server"
        case .daemonUnavailable:
            return "AFP helper daemon is not running"
        case .attachRequiresPassword:
            return "Volume password required"
        case .credentialsUnavailable(let status):
            return "AFP credentials unavailable (keychain status \(status))"
        case .loginFailed(let errno):
            let e = Self.absErrno(errno)
            return "AFP login failed (errno \(e): \(String(cString: strerror(e))))"
        case .resumeFailed(let errno):
            let e = Self.absErrno(errno)
            return "AFP resume failed (errno \(e): \(String(cString: strerror(e)))) — no live session"
        case .attachFailed(let errno):
            let e = Self.absErrno(errno)
            return "AFP volume attach failed (errno \(e): \(String(cString: strerror(e))))"
        case .passwordTooLong:
            return "AFP password too long (max 127 UTF-8 bytes)"
        case .unexpected(let message):
            return message
        }
    }

    /// True only for credential/login failures against the NAS (not keychain/resume/attach).
    public var isLoginFailure: Bool {
        if case .loginFailed = self { return true }
        return false
    }

    public var isCredentialsFailure: Bool {
        if case .credentialsUnavailable = self { return true }
        return false
    }

    /// Transient IPC / network failures that may recover after a short wait.
    public var isRetryable: Bool {
        if case .daemonUnavailable = self { return true }
        guard let code = rawErrno else { return false }
        switch code {
        case ECONNREFUSED, ECONNRESET, ETIMEDOUT, ENOTCONN, EAGAIN, EBUSY, EIO:
            return true
        default:
            return false
        }
    }

    public var rawErrno: Int32? {
        switch self {
        case .posix(let code), .loginFailed(let code), .resumeFailed(let code), .attachFailed(let code):
            return Self.absErrno(code)
        default:
            return nil
        }
    }

    public var operationName: String {
        switch self {
        case .credentialsUnavailable: return "credentials"
        case .loginFailed: return "login"
        case .resumeFailed: return "resume"
        case .attachFailed, .attachRequiresPassword: return "attach"
        case .daemonUnavailable: return "daemon"
        case .passwordTooLong: return "password"
        default: return "other"
        }
    }

    /// Shim / libafpsl return negative errno. Never treat bare `-1` as “daemon down”:
    /// on Darwin `EPERM == 1`, so `-EPERM == -1`. The C shim must resolve literal `-1`
    /// via `errno` before Swift sees it.
    public static func fromErrno(_ code: Int32) -> AFPError {
        let errnoCode = absErrno(code)
        if isDaemonErrno(errnoCode) {
            return .daemonUnavailable
        }
        return .posix(errnoCode)
    }

    public static func loginFromErrno(_ code: Int32) -> AFPError {
        let errnoCode = absErrno(code)
        if isDaemonErrno(errnoCode) {
            return .daemonUnavailable
        }
        return .loginFailed(errno: errnoCode)
    }

    public static func resumeFromErrno(_ code: Int32) -> AFPError {
        let errnoCode = absErrno(code)
        if isDaemonErrno(errnoCode) {
            return .daemonUnavailable
        }
        return .resumeFailed(errno: errnoCode)
    }

    public static func attachFromErrno(_ code: Int32) -> AFPError {
        let errnoCode = absErrno(code)
        if isDaemonErrno(errnoCode) {
            return .daemonUnavailable
        }
        return .attachFailed(errno: errnoCode)
    }

    private static func isDaemonErrno(_ code: Int32) -> Bool {
        // EPERM: sandboxed appex blocked from Unix-connecting to afpsld (e.g. /tmp).
        code == ECONNREFUSED || code == ENOENT || code == ENOTSOCK || code == EPERM
    }

    private static func absErrno(_ code: Int32) -> Int32 {
        code < 0 ? -code : code
    }
}
