import AFPBridge
import Foundation

/// Temporary host-side AFP login to enumerate volumes (Finder-style picker).
/// Always disconnects — does not leave a session for the FSKit appex to resume.
public enum AFPVolumeBrowser {
    public static func listVolumes(
        host: String,
        port: Int = 548,
        username: String = "",
        password: String = "",
        guest: Bool = false
    ) throws -> [String] {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw AFPError.invalidURL
        }

        let trimmedUser: String
        let resolvedPassword: String
        if guest {
            trimmedUser = ""
            resolvedPassword = ""
        } else {
            trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUser.isEmpty else {
                throw AFPError.unexpected("Username required")
            }
            guard !password.isEmpty else {
                throw AFPError.credentialsUnavailable(status: errSecItemNotFound)
            }
            resolvedPassword = password
        }

        try DaemonLauncher.shared.ensureRunning()

        let connectHost = HostResolver.preferredAFPHost(trimmedHost)
        let components = AFPURLComponents(
            username: trimmedUser,
            password: resolvedPassword,
            host: connectHost,
            port: port,
            volume: "",
            path: "/"
        )

        let client = AFPClient()
        defer {
            try? client.disconnect()
        }
        try client.connect(to: components, guest: guest)
        let names = try client.listVolumes()
        return names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
