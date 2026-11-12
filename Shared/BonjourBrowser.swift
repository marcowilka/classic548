import Foundation

/// Discovers `_afpovertcp._tcp` services on the LAN.
public final class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    public struct Service: Equatable, Identifiable, Sendable {
        public var id: String { "\(name).\(host):\(port)" }
        public let name: String
        public let host: String
        public let port: Int
    }

    public private(set) var services: [Service] = []
    public var onUpdate: (([Service]) -> Void)?

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    public override init() {
        super.init()
        browser.delegate = self
    }

    public func start() {
        browser.searchForServices(ofType: "_afpovertcp._tcp.", inDomain: "local.")
    }

    public func stop() {
        browser.stop()
        resolving.removeAll()
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name }
        onUpdate?(services)
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        // Prefer numeric IPv4 from the resolved address list — Synology .local
        // hostnames often yield unreachable IPv6 first (EHOSTUNREACH).
        let host = ipv4Host(from: sender)
            ?? sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            ?? sender.name
        let item = Service(name: sender.name, host: host, port: sender.port)
        if !services.contains(item) {
            services.append(item)
            onUpdate?(services)
        }
    }

    private func ipv4Host(from service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            var storage = sockaddr_storage()
            let copySize = min(MemoryLayout<sockaddr_storage>.size, data.count)
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafeMutableBytes(of: &storage) { dest in
                    dest.copyMemory(from: UnsafeRawBufferPointer(start: base, count: copySize))
                }
            }
            guard Int32(storage.ss_family) == AF_INET else { continue }
            var addr = withUnsafeBytes(of: &storage) { $0.load(as: sockaddr_in.self) }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(
                        sa,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        &buffer,
                        socklen_t(buffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
            }
            if result == 0 {
                let ip = String(cString: buffer)
                if !ip.isEmpty { return ip }
            }
        }
        return nil
    }
}
