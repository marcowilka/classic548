import Foundation
import Security

public enum AppConstants {
    public static let appBundleID = "de.marcowilka.classic548"
    public static let fsExtensionBundleID = "de.marcowilka.classic548.AFPFS"
    public static let fsShortName = "classic548"
    public static let keychainService = "de.marcowilka.classic548.afp"
    public static let bookmarksDefaultsKey = "bookmarks"
    public static let launchAtLoginKey = "launchAtLogin"

    /// Team ID from the running code signature (used for shared keychain access group).
    public static var teamID: String {
        if let cached = _teamIDCache { return cached }
        let resolved = Self.signingTeamID() ?? ""
        _teamIDCache = resolved
        return resolved
    }

    private static var _teamIDCache: String?

    private static func signingTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else {
            return nil
        }
        if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return team
        }
        return nil
    }
}
