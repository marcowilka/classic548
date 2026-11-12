import Foundation
import Security

public enum KeychainStore {
    /// Shared with the FSKit appex via `keychain-access-groups`.
    /// Must match `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` of the host app.
    public static let accessGroup = "\(AppConstants.teamID).\(AppConstants.appBundleID)"

    /// macOS login-keychain items get ACLs that prompt for access; FSKit appexes
    /// cannot show UI and fail with `errSecInteractionNotAllowed` (-25308).
    /// Data Protection keychain + access group is the supported appex path.
    private static let useDataProtection: [String: Any] = [
        kSecUseDataProtectionKeychain as String: true
    ]

    public static func savePassword(_ password: String, account: String, server: String, port: Int = 548) throws {
        try savePassword(password, account: account, servers: [server], port: port)
    }

    /// Persist the same secret under every host alias (bookmark name + resolved IP).
    public static func savePassword(
        _ password: String,
        account: String,
        servers: [String],
        port: Int = 548
    ) throws {
        var lastError: Error?
        var saved = false
        for server in uniqueServers(servers) {
            do {
                try savePasswordSingle(password, account: account, server: server, port: port)
                saved = true
            } catch {
                lastError = error
            }
        }
        if !saved, let lastError {
            throw lastError
        }
    }

    public static func password(account: String, server: String, port: Int = 548) -> String? {
        password(account: account, servers: [server], port: port)
    }

    /// Try bookmark host first, then aliases (e.g. resolved IPv4).
    public static func password(account: String, servers: [String], port: Int = 548) -> String? {
        let aliases = uniqueServers(servers)
        for server in aliases {
            if let shared = copyGeneric(account: account, server: server, port: port, shared: true) {
                // Fill missing aliases without running destructive legacy cleanup.
                mirrorToMissingAliases(shared, account: account, servers: aliases, port: port, present: server)
                return shared
            }
        }
        for server in aliases {
            if let legacyShared = copyInternet(account: account, server: server, port: port, shared: true) {
                try? savePassword(legacyShared, account: account, servers: aliases, port: port)
                return legacyShared
            }
            if let legacy = copyInternet(account: account, server: server, port: port, shared: false)
                ?? copyGeneric(account: account, server: server, port: port, shared: false)
            {
                try? savePassword(legacy, account: account, servers: aliases, port: port)
                return legacy
            }
        }
        return nil
    }

    public static func deletePassword(account: String, servers: [String], port: Int = 548) {
        for server in uniqueServers(servers) {
            deletePassword(account: account, server: server, port: port)
        }
    }

    private static func uniqueServers(_ servers: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for raw in servers {
            let server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !server.isEmpty, !seen.contains(server) else { continue }
            seen.insert(server)
            ordered.append(server)
        }
        return ordered
    }

    private static func mirrorToMissingAliases(
        _ password: String,
        account: String,
        servers: [String],
        port: Int,
        present: String
    ) {
        for server in servers where server != present {
            if copyGeneric(account: account, server: server, port: port, shared: true) == nil {
                try? savePasswordSingle(password, account: account, server: server, port: port)
            }
        }
    }

    private static func savePasswordSingle(_ password: String, account: String, server: String, port: Int) throws {
        let data = Data(password.utf8)
        let updateQuery = genericQuery(account: account, server: server, port: port, shared: true)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            // Only scrub internet-password leftovers — never delete generic with the
            // same service/account (legacy deletes without DP flag wipe this item).
            deleteInternetPasswordLeftovers(account: account, server: server, port: port)
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unhandled(updateStatus)
        }

        var add = genericQuery(account: account, server: server, port: port, shared: true)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retry = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
            guard retry == errSecSuccess else {
                throw KeychainError.unhandled(retry)
            }
        } else if addStatus != errSecSuccess {
            throw KeychainError.unhandled(addStatus)
        }
        deleteInternetPasswordLeftovers(account: account, server: server, port: port)

        // Confirm the DP item is readable; surface add/query mismatches early.
        let status = passwordStatus(account: account, server: server, port: port)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Diagnostic helper for the appex / Diagnostics window.
    public static func passwordStatus(account: String, server: String, port: Int = 548) -> OSStatus {
        var query = genericQuery(account: account, server: server, port: port, shared: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    public static func describeStatus(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:
            return "ok"
        case errSecItemNotFound:
            return "notFound(-25300)"
        case errSecInteractionNotAllowed:
            return "interactionNotAllowed(-25308) — item not readable from appex (need data-protection keychain)"
        case errSecAuthFailed:
            return "authFailed(-25293)"
        case errSecMissingEntitlement:
            return "missingEntitlement(-34018)"
        default:
            return "status(\(status))"
        }
    }

    public static func deletePassword(account: String, server: String, port: Int = 548) {
        SecItemDelete(genericQuery(account: account, server: server, port: port, shared: true) as CFDictionary)
        // Intentionally do not delete genericQuery(shared: false) — on macOS that
        // can match the default access group and wipe the shared DP item.
        deleteInternetPasswordLeftovers(account: account, server: server, port: port)
    }

    /// Only `kSecClassInternetPassword` leftovers from older builds.
    private static func deleteInternetPasswordLeftovers(account: String, server: String, port: Int) {
        SecItemDelete(internetQuery(account: account, server: server, port: port, shared: true) as CFDictionary)
        SecItemDelete(internetQuery(account: account, server: server, port: port, shared: false) as CFDictionary)
    }

    private static func copyGeneric(account: String, server: String, port: Int, shared: Bool) -> String? {
        var query = genericQuery(account: account, server: server, port: port, shared: shared)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private static func copyInternet(account: String, server: String, port: Int, shared: Bool) -> String? {
        var query = internetQuery(account: account, server: server, port: port, shared: shared)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func accountKey(account: String, server: String, port: Int) -> String {
        "\(account)@\(server):\(port)"
    }

    private static func genericQuery(account: String, server: String, port: Int, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: accountKey(account: account, server: server, port: port)
        ]
        query.merge(useDataProtection) { _, new in new }
        if shared {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Legacy shape from earlier builds (internet password).
    private static func internetQuery(account: String, server: String, port: Int, shared: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server,
            kSecAttrAccount as String: account,
            kSecAttrPort as String: port,
            kSecAttrProtocol as String: kSecAttrProtocolAFP
        ]
        query.merge(useDataProtection) { _, new in new }
        if shared {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    public enum KeychainError: Error, LocalizedError {
        case unhandled(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                return "Keychain error \(KeychainStore.describeStatus(status))"
            }
        }
    }
}
