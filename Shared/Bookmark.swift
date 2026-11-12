import Foundation

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var volume: String
    public var username: String
    public var guestAccess: Bool
    public var autoConnect: Bool
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        host: String,
        port: Int = 548,
        volume: String,
        username: String = "",
        guestAccess: Bool = false,
        autoConnect: Bool = false,
        lastError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName.isEmpty ? "\(volume) on \(host)" : displayName
        self.host = host
        self.port = port
        self.volume = volume
        self.username = guestAccess ? "" : username
        self.guestAccess = guestAccess
        self.autoConnect = autoConnect
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, host, port, volume, username, guestAccess, autoConnect, lastError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        volume = try c.decode(String.self, forKey: .volume)
        username = try c.decode(String.self, forKey: .username)
        guestAccess = try c.decodeIfPresent(Bool.self, forKey: .guestAccess) ?? false
        autoConnect = try c.decode(Bool.self, forKey: .autoConnect)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        if guestAccess {
            username = ""
        }
    }

    public var afpURLString: String {
        var s = "afp://"
        if !guestAccess, !username.isEmpty {
            s += "\(username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username)@"
        }
        s += host
        if port != 548 {
            s += ":\(port)"
        }
        let vol = volume.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? volume
        s += "/\(vol)"
        return s
    }

    public var afpURL: URL? {
        URL(string: afpURLString)
    }

    /// Same AFP mount target (host + port + volume). Multiple favorites may share a host.
    public func matchesMountTarget(host: String, port: Int, volume: String) -> Bool {
        self.port == port
            && self.host.caseInsensitiveCompare(host) == .orderedSame
            && self.volume.caseInsensitiveCompare(volume) == .orderedSame
    }

    public func matchesMountTarget(_ other: Bookmark) -> Bool {
        matchesMountTarget(host: other.host, port: other.port, volume: other.volume)
    }
}
