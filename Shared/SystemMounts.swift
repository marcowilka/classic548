import Foundation

/// Live FSKit mounts belonging to ClassicAFP (`fstypename == classic548`).
public enum SystemMounts {
    public struct Entry: Sendable {
        public let mountPath: String
        public let from: String // e.g. afp://user@host/volume
        public var url: URL { URL(fileURLWithPath: mountPath) }
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

    /// Match a bookmark to an existing classic548 mount (by volume name / afp URL).
    public static func existingMount(for bookmark: Bookmark) -> Entry? {
        let mounts = classic548Mounts()
        let volume = bookmark.volume
        let host = bookmark.host.lowercased()
        let preferred = HostResolver.preferredAFPHost(bookmark.host).lowercased()
        return mounts.first { entry in
            if !isReachable(entry.mountPath) { return false }
            let from = entry.from.lowercased()
            if !volume.isEmpty, from.hasSuffix("/\(volume.lowercased())") { return true }
            if from.contains(host) || from.contains(preferred) {
                let last = URL(fileURLWithPath: entry.mountPath).lastPathComponent
                return volume.isEmpty || last.caseInsensitiveCompare(volume) == .orderedSame
            }
            let last = URL(fileURLWithPath: entry.mountPath).lastPathComponent
            return !volume.isEmpty && last.caseInsensitiveCompare(volume) == .orderedSame
        }
    }
}
