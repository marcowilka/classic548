import AFPBridge
import Foundation

/// Live FSKit mounts belonging to ClassicAFP (`fstypename == classic548`).
public enum SystemMounts {
    public struct Entry: Sendable {
        public let mountPath: String
        public let from: String // e.g. afp://user@host/volume
        public var url: URL { URL(fileURLWithPath: mountPath) }

        public var afpComponents: AFPURLComponents? {
            SystemMounts.parseMountFrom(from)
        }
    }

    public static func classic548Mounts() -> [Entry] {
        var entries: [Entry] = []
        var mntbuf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mntbuf, MNT_NOWAIT)
        guard count > 0, let mntbuf else { return [] }
        for i in 0..<Int(count) {
            let st = mntbuf[i]
            let fstype = withUnsafePointer(to: st.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0)
                }
            }
            guard fstype == AppConstants.fsShortName else { continue }
            let on = withUnsafePointer(to: st.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            let from = withUnsafePointer(to: st.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                    String(cString: $0)
                }
            }
            entries.append(Entry(mountPath: on, from: from))
        }
        return entries
    }

    public static func isReachable(_ path: String) -> Bool {
        var st = stat()
        return path.withCString { stat($0, &st) == 0 }
    }

    /// Parse `f_mntfromname` as an AFP URL (tolerant of missing scheme).
    public static func parseMountFrom(_ from: String) -> AFPURLComponents? {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let parsed = AFPURLComponents.parse(url) {
            return parsed
        }
        if trimmed.lowercased().hasPrefix("afp://"),
           let url = URL(string: trimmed),
           let parsed = AFPURLComponents.parse(url) {
            return parsed
        }
        // Some kernels store host/volume without a scheme.
        if let url = URL(string: "afp://\(trimmed)"), let parsed = AFPURLComponents.parse(url) {
            return parsed
        }
        return nil
    }

    /// Match a bookmark to an existing classic548 mount by host/port/volume/user only.
    public static func existingMount(for bookmark: Bookmark) -> Entry? {
        let mounts = classic548Mounts()
        let volume = bookmark.volume.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !volume.isEmpty else { return nil }

        let hosts = allowedHosts(for: bookmark)
        let port = bookmark.port == 0 ? 548 : bookmark.port
        let user = bookmark.guestAccess
            ? ""
            : bookmark.username.trimmingCharacters(in: .whitespacesAndNewlines)

        return mounts.first { entry in
            guard isReachable(entry.mountPath) else { return false }
            guard let parsed = entry.afpComponents else { return false }
            guard parsed.volume.caseInsensitiveCompare(volume) == .orderedSame else { return false }
            let parsedPort = parsed.port == 0 ? 548 : parsed.port
            guard parsedPort == port else { return false }
            guard hosts.contains(where: { $0.caseInsensitiveCompare(parsed.host) == .orderedSame }) else {
                return false
            }
            let parsedUser = parsed.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return parsedUser.caseInsensitiveCompare(user) == .orderedSame
        }
    }

    private static func allowedHosts(for bookmark: Bookmark) -> [String] {
        var hosts = [bookmark.host]
        let preferred = HostResolver.preferredAFPHost(bookmark.host)
        if preferred.caseInsensitiveCompare(bookmark.host) != .orderedSame {
            hosts.append(preferred)
        }
        return hosts
    }
}
