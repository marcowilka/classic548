import AFPBridge
import AppKit
import Foundation
import FSKit

@MainActor
public final class MountController {
    public static let shared = MountController()

    public private(set) var mounted: [UUID: URL] = [:]
    public var statusMessage: String = L10n.ready
    public var onChange: (() -> Void)?

    private let extensionBundleID = AppConstants.fsExtensionBundleID

    public func mount(_ bookmark: Bookmark, password: String?) async {
        DiagnosticsLog.shared.info("Mount requested: \(bookmark.displayName) → \(bookmark.afpURLString)")
        do {
            try await preflightFSKit()

            // Prefer IPv4 for *.local — IPv6-first mDNS often yields EHOSTUNREACH on Synology.
            let connectHost = HostResolver.preferredAFPHost(bookmark.host)
            if connectHost != bookmark.host {
                DiagnosticsLog.shared.info("Resolved \(bookmark.host) → \(connectHost) (IPv4)")
            }
            var mountBookmark = bookmark
            mountBookmark.host = connectHost

            // Adopt / clear BEFORE touching the daemon — restarting afpsld under a
            // live /Volumes mount is what produced EINVAL + EBUSY loops.
            if let existing = SystemMounts.existingMount(for: mountBookmark)
                ?? SystemMounts.existingMount(for: bookmark)
            {
                if SystemMounts.isReachable(existing.mountPath) {
                    mounted[bookmark.id] = existing.url
                    clearLastError(bookmark)
                    statusMessage = L10n.mounted(bookmark.displayName)
                    DiagnosticsLog.shared.info(
                        "Adopted existing mount at \(existing.mountPath) (\(existing.from))"
                    )
                    presentInFinder(existing.url)
                    onChange?()
                    return
                }
                DiagnosticsLog.shared.info(
                    "Dead mount at \(existing.mountPath) — force-unmounting before remount"
                )
                try? await eject(url: existing.url, force: true)
            }

            guard try DaemonLauncher.shared.ensureRunning() else {
                throw MountError.daemonNotRunning
            }
            DiagnosticsLog.shared.info("afpsld is running")

            guard let password, !password.isEmpty else {
                throw MountError.missingPassword
            }

            // Appex reads this under the shared keychain-access-group. Must succeed.
            let keychainServers = [bookmark.host, connectHost]
            try KeychainStore.savePassword(
                password,
                account: bookmark.username,
                servers: keychainServers,
                port: bookmark.port
            )
            let verifyStatus = KeychainStore.passwordStatus(
                account: bookmark.username,
                server: connectHost,
                port: bookmark.port
            )
            let readable = KeychainStore.password(
                account: bookmark.username,
                servers: keychainServers,
                port: bookmark.port
            )
            DiagnosticsLog.shared.info(
                "Keychain saved for \(bookmark.username)@\(keychainServers.joined(separator: "|")) group=\(KeychainStore.accessGroup) \(KeychainStore.describeStatus(verifyStatus)) readable=\(readable != nil)"
            )
            guard readable != nil else {
                throw KeychainStore.KeychainError.unhandled(
                    verifyStatus == errSecSuccess ? errSecItemNotFound : verifyStatus
                )
            }

            try await preflightNetwork(host: connectHost, port: bookmark.port)

            guard let finalURL = URL(string: mountBookmark.afpURLString) else {
                fail("Invalid AFP URL", bookmark: bookmark)
                return
            }

            let resource = FSGenericURLResource(url: finalURL)
            DiagnosticsLog.shared.info("Calling FSClient.mountSingleVolume for \(extensionBundleID)")
            let mountURL: URL
            do {
                mountURL = try await mountSingleVolume(resource: resource)
            } catch {
                let ns = error as NSError
                if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EBUSY) {
                    if let stale = expectedVolumeURL(for: mountBookmark)
                        ?? SystemMounts.classic548Mounts().first(where: {
                            $0.from.lowercased().contains(connectHost.lowercased())
                        })?.url
                    {
                        DiagnosticsLog.shared.info("EBUSY — force-unmounting \(stale.path) then retry")
                        try? await eject(url: stale, force: true)
                    }
                    mountURL = try await mountSingleVolume(resource: resource)
                } else {
                    throw error
                }
            }
            mounted[bookmark.id] = mountURL
            clearLastError(bookmark)
            statusMessage = L10n.mounted(bookmark.displayName)
            DiagnosticsLog.shared.info("Mounted at \(mountURL.path)")
            presentInFinder(mountURL)
            onChange?()
        } catch {
            let message = friendlyMessage(for: error)
            DiagnosticsLog.shared.error(error, context: "mount")
            fail(message, bookmark: bookmark, persistError: !isTransientMountError(error))
        }
    }

    /// Auto-connect path: one retry after launch races; never leave a sticky error in the menu.
    public func mountForAutoConnect(_ bookmark: Bookmark, password: String?) async {
        if isMounted(bookmark) { return }
        statusMessage = L10n.connecting(bookmark.displayName)
        onChange?()
        await mount(bookmark, password: password)
        if isMounted(bookmark) { return }

        DiagnosticsLog.shared.info("Auto-connect retry for \(bookmark.displayName)")
        statusMessage = L10n.connecting(bookmark.displayName)
        onChange?()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await mount(bookmark, password: password)

        if !isMounted(bookmark) {
            // Details stay in Diagnostics / latest.log — menu stays calm.
            statusMessage = L10n.ready
            onChange?()
        }
    }

    /// Sync in-memory mount table with live classic548 mounts (survives app relaunch).
    public func reconcileMountedVolumes() {
        let bookmarks = BookmarkStore.shared.load()
        var next: [UUID: URL] = [:]
        for bookmark in bookmarks {
            if let existing = SystemMounts.existingMount(for: bookmark) {
                next[bookmark.id] = existing.url
            } else if let url = mounted[bookmark.id], SystemMounts.isReachable(url.path) {
                next[bookmark.id] = url
            }
        }
        // Keep unknown live mounts mapped if we still have the id.
        for (id, url) in mounted where next[id] == nil {
            if SystemMounts.isReachable(url.path) {
                next[id] = url
            }
        }
        mounted = next
        if next.isEmpty {
            if statusMessage.hasPrefix("AFP ") || statusMessage.localizedCaseInsensitiveContains("failed") {
                statusMessage = L10n.ready
            }
        } else if next.count == 1,
                  let name = bookmarks.first(where: { next[$0.id] != nil })?.displayName
        {
            statusMessage = L10n.mounted(name)
        } else {
            statusMessage = L10n.mountedCount(next.count)
        }
        onChange?()
    }

    public var hasLiveMounts: Bool {
        !SystemMounts.classic548Mounts().filter { SystemMounts.isReachable($0.mountPath) }.isEmpty
            || mounted.values.contains { SystemMounts.isReachable($0.path) }
    }

    public func reveal(_ bookmark: Bookmark) {
        guard let url = mounted[bookmark.id] ?? SystemMounts.existingMount(for: bookmark)?.url else {
            statusMessage = L10n.notMounted
            onChange?()
            return
        }
        presentInFinder(url)
    }

    public func unmount(_ bookmark: Bookmark) async {
        guard let url = mounted[bookmark.id] ?? SystemMounts.existingMount(for: bookmark)?.url else {
            mounted.removeValue(forKey: bookmark.id)
            statusMessage = L10n.notMounted
            onChange?()
            return
        }
        do {
            // FSKit volumes are not diskutil "disks" — `eject` fails with
            // "Failed to find disk". Use unmount, then force if busy.
            try await eject(url: url, force: false)
            mounted.removeValue(forKey: bookmark.id)
            statusMessage = L10n.ejected(bookmark.displayName)
            DiagnosticsLog.shared.info("Ejected \(url.path)")
            onChange?()
        } catch {
            DiagnosticsLog.shared.error(error, context: "unmount")
            // If the path is already gone, treat as success.
            if !SystemMounts.isReachable(url.path),
               SystemMounts.classic548Mounts().allSatisfy({ $0.mountPath != url.path })
            {
                mounted.removeValue(forKey: bookmark.id)
                statusMessage = L10n.ejected(bookmark.displayName)
                onChange?()
                return
            }
            statusMessage = friendlyMessage(for: error)
            onChange?()
        }
    }

    /// Best-effort unmount of every classic548 volume (used on Quit).
    public func unmountAllSync() {
        let urls = Set(
            mounted.values.map(\.path) + SystemMounts.classic548Mounts().map(\.mountPath)
        ).map { URL(fileURLWithPath: $0) }
        for url in urls {
            let output = runDiskutil(["unmount", "force", url.path])
            DiagnosticsLog.shared.info("Quit unmount \(url.path): \(output.status == 0 ? "ok" : output.text)")
        }
        mounted.removeAll()
        statusMessage = L10n.ready
    }

    public func resetStatusForLaunch() {
        statusMessage = L10n.ready
        onChange?()
    }

    public func isMounted(_ bookmark: Bookmark) -> Bool {
        if let url = mounted[bookmark.id], SystemMounts.isReachable(url.path) {
            return true
        }
        return SystemMounts.existingMount(for: bookmark) != nil
    }

    private func mountSingleVolume(resource: FSGenericURLResource) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            FSClient.shared.mountSingleVolume(
                resource: resource,
                bundleID: extensionBundleID,
                options: []
            ) { path, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let path {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(throwing: POSIXError(.EIO))
                }
            }
        }
    }

    private func presentInFinder(_ url: URL) {
        FinderAccess.revealVolume(at: url)
    }

    private func expectedVolumeURL(for bookmark: Bookmark) -> URL? {
        let name = bookmark.volume.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return URL(fileURLWithPath: "/Volumes/\(name)")
    }

    public func openExtensionSettings() {
        _ = FSClient.shared.openFileSystemExtensionsSettings()
    }

    public func refreshExtensionStatus() async -> String {
        do {
            let modules = try await FSClient.shared.installedExtensions
            let match = modules.first { $0.bundleIdentifier == extensionBundleID }
            if let match {
                let state = match.isEnabled ? "enabled" : "disabled"
                let summary = "FSKit module \(match.bundleIdentifier) is \(state)"
                DiagnosticsLog.shared.info(summary)
                return summary
            }
            let summary = "FSKit module \(extensionBundleID) not listed — enable File System Extensions or check fskit.fsmodule entitlement"
            DiagnosticsLog.shared.error(summary)
            return summary
        } catch {
            DiagnosticsLog.shared.error(error, context: "installedExtensions")
            return friendlyMessage(for: error)
        }
    }

    private func preflightFSKit() async throws {
        let modules = try await FSClient.shared.installedExtensions
        DiagnosticsLog.shared.info("Installed FSKit modules: \(modules.map { "\($0.bundleIdentifier)(enabled=\($0.isEnabled))" }.joined(separator: ", "))")
        guard let match = modules.first(where: { $0.bundleIdentifier == extensionBundleID }) else {
            openExtensionSettings()
            throw MountError.extensionMissing
        }
        guard match.isEnabled else {
            let stale = modules
                .filter {
                    $0.bundleIdentifier != extensionBundleID
                        && ($0.bundleIdentifier.contains("classic548")
                            || $0.bundleIdentifier.contains("ClassicAFP"))
                }
                .map { "\($0.bundleIdentifier)(enabled=\($0.isEnabled))" }
            if !stale.isEmpty {
                DiagnosticsLog.shared.info("Stale AFP FSKit modules still listed: \(stale.joined(separator: ", "))")
            }
            DiagnosticsLog.shared.info("Opening File System Extensions — enable \(extensionBundleID)")
            openExtensionSettings()
            throw MountError.extensionDisabled
        }
    }

    private func preflightNetwork(host: String, port: Int) async throws {
        let socketPath = AFPIPC.socketPath
        let socketOK = FileManager.default.fileExists(atPath: socketPath)
        let proxyOK = AFPSLTCPProxy.shared.isRunning
        DiagnosticsLog.shared.info(
            "afpsld socket \(socketPath) exists=\(socketOK) tcpProxy=\(proxyOK) port=\(AFPIPC.tcpProxyPort) uid=\(getuid())"
        )
        guard socketOK else {
            throw MountError.daemonNotRunning
        }
        if !proxyOK {
            try AFPSLTCPProxy.shared.ensureRunning(unixSocketPath: socketPath)
        }
        DiagnosticsLog.shared.info("AFP TCP check \(host):\(port)")
        try await Task.detached(priority: .userInitiated) {
            var hints = addrinfo(
                ai_flags: 0,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            let gai = portStr.withCString { portC in
                host.withCString { hostC in
                    getaddrinfo(hostC, portC, &hints, &result)
                }
            }
            defer { if let result { freeaddrinfo(result) } }
            guard gai == 0, let first = result, let addr = first.pointee.ai_addr else {
                throw AFPError.posix(EHOSTUNREACH)
            }
            let fd = socket(first.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { throw AFPError.posix(errno) }
            defer { close(fd) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let rc = connect(fd, addr, first.pointee.ai_addrlen)
            if rc != 0 {
                throw AFPError.posix(errno == 0 ? EHOSTUNREACH : errno)
            }
        }.value
        DiagnosticsLog.shared.info("AFP TCP OK — appex will authenticate via keychain")
    }

    private func fail(_ message: String, bookmark: Bookmark, persistError: Bool = true) {
        statusMessage = message
        if persistError {
            var updated = bookmark
            updated.lastError = message
            BookmarkStore.shared.upsert(updated)
        }
        onChange?()
    }

    private func clearLastError(_ bookmark: Bookmark) {
        guard bookmark.lastError != nil else { return }
        var updated = bookmark
        updated.lastError = nil
        BookmarkStore.shared.upsert(updated)
    }

    private func isTransientMountError(_ error: Error) -> Bool {
        if let afp = error as? AFPError, afp.isRetryable { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return [EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED, EBUSY, EAGAIN]
                .contains(Int32(ns.code))
        }
        if ns.domain == "AFPBridge.AFPError", let errno = ns.userInfo["AFPErrno"] as? Int {
            return [Int(EHOSTUNREACH), Int(ENETUNREACH), Int(ETIMEDOUT), Int(ECONNREFUSED)].contains(errno)
        }
        return false
    }

    private func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        if let mountError = error as? MountError {
            return mountError.errorDescription ?? ns.localizedDescription
        }
        if let keychainError = error as? KeychainStore.KeychainError {
            return keychainError.errorDescription ?? "Keychain save failed"
        }
        if let afp = error as? AFPError {
            if afp.isCredentialsFailure {
                return "AFP credentials unavailable from keychain — remount after saving the password (see /tmp/classic548-extension.log)"
            }
            if afp.isLoginFailure {
                if afp.rawErrno == EHOSTUNREACH || afp.rawErrno == ENETUNREACH {
                    return "AFP server unreachable during login — retry in a moment"
                }
                return "AFP login failed — check username/password (see Diagnostics)"
            }
            if case .passwordTooLong = afp {
                return afp.errorDescription ?? "Password too long"
            }
            if case .attachFailed = afp {
                return "AFP volume attach failed after login (see /tmp/classic548-extension.log)"
            }
            if case .resumeFailed = afp {
                return "AFP resume failed — no live session (see /tmp/classic548-extension.log)"
            }
            return afp.errorDescription ?? ns.localizedDescription
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EPERM) {
            return "FSKit mount not permitted — missing com.apple.developer.fskit.mount or extension disabled (see Diagnostics)"
        }
        if ns.domain == "AFPBridge.AFPError" {
            let op = ns.userInfo["AFPOperation"] as? String
            if op == "credentials" || ns.code == 1008 {
                return "AFP credentials unavailable from keychain — remount after saving the password (see /tmp/classic548-extension.log)"
            }
            if op == "login" || ns.code == 1005 {
                return "AFP login failed — check username/password (see /tmp/classic548-extension.log)"
            }
            if op == "attach" {
                return "AFP volume attach failed after login (see /tmp/classic548-extension.log)"
            }
            if let detail = ns.userInfo[NSLocalizedDescriptionKey] as? String, !detail.isEmpty {
                return detail
            }
        }
        if ns.localizedDescription.localizedCaseInsensitiveContains("not permitted") {
            return "FSKit mount not permitted — enable File System Extensions / grant fskit.mount (see Diagnostics)"
        }
        let combined = "\(ns.domain) \(ns.localizedDescription) \(ns.userInfo)"
        if combined.localizedCaseInsensitiveContains("same bundle ID already exists with a different path") {
            return "FSKit extension path conflict — quit ClassicAFP + Finder, then: pluginkit -r -i \(AppConstants.fsExtensionBundleID); use one build only (Xcode Run OR build/, not both), enable the appex again"
        }
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    private func eject(url: URL, force: Bool) async throws {
        // Ask Finder to release the folder before unmount.
        NSWorkspace.shared.noteFileSystemChanged(url.path)

        let attempts: [[String]] = {
            if force {
                return [
                    ["unmount", "force", url.path],
                    ["unmount", "force", url.path]
                ]
            }
            return [
                ["unmount", url.path],
                ["unmount", "force", url.path]
            ]
        }()

        var lastText = ""
        for args in attempts {
            let result = runDiskutil(args)
            lastText = result.text
            if result.status == 0 {
                // Wait briefly for the mount table to drop the entry.
                for _ in 0..<20 {
                    if !FileManager.default.fileExists(atPath: url.path)
                        || !SystemMounts.isReachable(url.path)
                    {
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                return
            }
            DiagnosticsLog.shared.info("diskutil \(args.joined(separator: " ")): \(result.text)")
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        // Last resort: umount(8) — often EPERM for FSKit; still try.
        let umount = runProcess(
            "/sbin/umount",
            force ? ["-f", url.path] : [url.path]
        )
        if umount.status == 0 { return }
        DiagnosticsLog.shared.error("umount failed: \(umount.text)")
        throw POSIXError(.EBUSY)
    }

    private func runDiskutil(_ arguments: [String]) -> (status: Int32, text: String) {
        runProcess("/usr/sbin/diskutil", arguments)
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) -> (status: Int32, text: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (task.terminationStatus, text)
    }

    public enum MountError: Error, LocalizedError {
        case extensionMissing
        case extensionDisabled
        case daemonNotRunning
        case missingPassword

        public var errorDescription: String? {
            switch self {
            case .extensionMissing:
                return "AFP FSKit extension not installed/visible — open File System Extensions and check fskit.fsmodule entitlement"
            case .extensionDisabled:
                return "Enable \(AppConstants.fsExtensionBundleID) under File System Extensions (disable any old io.classic548… copy)"
            case .daemonNotRunning:
                return "AFP helper daemon (afpsld) failed to start"
            case .missingPassword:
                return "No password — save one in Preferences or enter it when connecting"
            }
        }
    }
}
