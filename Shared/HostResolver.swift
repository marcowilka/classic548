import Foundation

/// Prefers IPv4 for Bonjour/mDNS hosts. Synology `.local` names often resolve to
/// an unreachable IPv6 first (EHOSTUNREACH / POSIX 65) even when IPv4 works —
/// the same quirk Finder hits with DiskStation.local.
public enum HostResolver {
    public static func preferredAFPHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeLocalBonjour(trimmed) else { return trimmed }
        if let ipv4 = resolveIPv4(trimmed) {
            return ipv4
        }
        return trimmed
    }

    public static func looksLikeLocalBonjour(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.hasSuffix(".local") || lower.hasSuffix(".local.")
    }

    private static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "548", &hints, &result)
        defer { if let result { freeaddrinfo(result) } }
        guard status == 0, let first = result, let addr = first.pointee.ai_addr else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ni = getnameinfo(
            addr,
            socklen_t(first.pointee.ai_addrlen),
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard ni == 0 else { return nil }
        let ip = String(cString: buffer)
        return ip.isEmpty ? nil : ip
    }
}
