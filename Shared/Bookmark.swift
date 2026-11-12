import Foundation

public struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var port: Int
    public var volume: String
    public var username: String
    public var autoConnect: Bool
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        displayName: String = "",
        host: String,
        port: Int = 548,
        volume: String,
        username: String = "",
        autoConnect: Bool = false,
        lastError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName.isEmpty ? "\(volume) on \(host)" : displayName
        self.host = host
        self.port = port
        self.volume = volume
        self.username = username
        self.autoConnect = autoConnect
        self.lastError = lastError
    }

    public var afpURLString: String {
        var s = "afp://"
        if !username.isEmpty {
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
}
