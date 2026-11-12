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
            reply(nil, error)
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
