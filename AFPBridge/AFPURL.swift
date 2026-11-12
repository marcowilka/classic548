import Foundation

public struct AFPURLComponents: Sendable, Equatable {
    public var username: String
    public var password: String
    public var host: String
    public var port: Int
    public var volume: String
    public var path: String

    public init(
        username: String = "",
        password: String = "",
        host: String,
        port: Int = 548,
        volume: String,
        path: String = "/"
    ) {
        self.username = username
        self.password = password
        self.host = host
        self.port = port == 0 ? 548 : port
        self.volume = volume
        self.path = path.isEmpty ? "/" : path
    }

    public var displayName: String {
        volume.isEmpty ? host : "\(volume) on \(host)"
    }

    /// `afp://user@host:port/volume/path`
    public var url: URL? {
        var allowed = CharacterSet.urlUserAllowed
        allowed.insert(charactersIn: "@")
        var string = "afp://"
        if !username.isEmpty {
            let user = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            string += "\(user)@"
        }
        string += host
        if port != 548 {
            string += ":\(port)"
        }
        let vol = volume.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? volume
        string += "/\(vol)"
        if path != "/" {
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
            string += "/\(encoded)"
        }
        return URL(string: string)
    }

    public static func parse(_ url: URL) -> AFPURLComponents? {
        guard let scheme = url.scheme?.lowercased(), scheme == "afp" else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        let pathParts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let volume = pathParts.first else { return nil }
        let remainder = pathParts.dropFirst().joined(separator: "/")
        return AFPURLComponents(
            username: url.user ?? "",
            password: url.password ?? "",
            host: host,
            port: url.port ?? 548,
            volume: volume,
            path: remainder.isEmpty ? "/" : "/\(remainder)"
        )
    }
}
