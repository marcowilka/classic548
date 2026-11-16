import AFPBridge
import Foundation
import FSKit
import os.log

private let log = Logger(subsystem: AppConstants.fsExtensionBundleID, category: "FS")

final class AFPFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private var activeVolume: AFPVolume?

    func didFinishLoading() {
        let socketPath = AFPIPC.socketPath
        setenv("AFPSL_SOCKET_PATH", socketPath, 1)
        setenv("AFPSL_TCP_PORT", AFPIPC.tcpProxyPortEnv, 1)
        log.info(
            "AFP FSKit extension loaded socket=\(socketPath, privacy: .public) tcpPort=\(AFPIPC.tcpProxyPort)"
        )
    }

    func probeResource(resource: FSResource, replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let generic = resource as? FSGenericURLResource else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        guard let scheme = generic.url.scheme?.lowercased(), scheme == "afp" else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        let name = generic.url.lastPathComponent.isEmpty ? (generic.url.host ?? "AFP") : generic.url.lastPathComponent
        let containerID = FSContainerIdentifier(uuid: UUID())
        reply(FSProbeResult.usable(name: name, containerID: containerID), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let generic = resource as? FSGenericURLResource else {
            reply(nil, fs_error(.EINVAL, "Expected FSGenericURLResource"))
            return
        }
        do {
            let volume = try AFPVolume(url: generic.url)
            activeVolume = volume
            containerStatus = .ready
            reply(volume, nil)
        } catch {
            log.error("loadResource failed: \(error.localizedDescription, privacy: .public)")
            reply(nil, fs_bridge(error))
        }
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        activeVolume?.shutdown()
        activeVolume = nil
        reply(nil)
    }
}

func fs_error(_ code: POSIXErrorCode, _ message: String) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code.rawValue),
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

/// FSKit requires `NSPOSIXErrorDomain`. Foreign domains (e.g. `AFPBridge.AFPError`)
/// collapse to EINVAL in VFS — bridge every reply failure through here.
func fs_bridge(_ error: Error) -> NSError {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain {
        return ns
    }
    if let afp = error as? AFPError {
        let code: Int32
        if let errnoCode = afp.rawErrno {
            code = errnoCode
        } else {
            switch afp {
            case .loginFailed, .credentialsUnavailable:
                code = EAUTH
            case .daemonUnavailable, .resumeFailed, .notConnected:
                code = ENOTCONN
            case .attachRequiresPassword, .attachFailed:
                code = EACCES
            case .passwordTooLong, .fieldTooLong, .invalidURL:
                code = EINVAL
            default:
                code = EIO
            }
        }
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: afp.localizedDescription]
        )
    }
    return fs_error(.EIO, ns.localizedDescription)
}
