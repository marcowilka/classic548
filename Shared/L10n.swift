import Foundation

/// Centralized UI strings. Keys live in `Resources/Localizable.xcstrings`.
public enum L10n {
    public static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = String(localized: String.LocalizationValue(key), bundle: .main)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: .current, arguments: args)
    }

    // Favorites window
    public static var favoritesTitle: String { t("favorites.title") }
    public static var displayName: String { t("favorites.displayName") }
    public static var host: String { t("favorites.host") }
    public static var port: String { t("favorites.port") }
    public static var volume: String { t("favorites.volume") }
    public static var selectVolume: String { t("favorites.selectVolume") }
    public static var refreshVolumes: String { t("favorites.refreshVolumes") }
    public static var refreshNeedsCredentials: String { t("favorites.refreshNeedsCredentials") }
    public static var enterCredentials: String { t("favorites.enterCredentials") }
    public static var loadingVolumes: String { t("favorites.loadingVolumes") }
    public static var noVolumes: String { t("favorites.noVolumes") }
    public static func volumeLoadFailed(_ detail: String) -> String { t("favorites.volumeLoadFailed", detail) }
    public static var username: String { t("favorites.username") }
    public static var password: String { t("favorites.password") }
    public static var guestAccess: String { t("favorites.guestAccess") }
    public static var connectAtLogin: String { t("favorites.connectAtLogin") }
    public static var launchAtLogin: String { t("favorites.launchAtLogin") }
    public static var addUpdate: String { t("favorites.addUpdate") }
    public static var remove: String { t("favorites.remove") }
    public static var connect: String { t("favorites.connect") }

    // Menu
    public static var ready: String { t("menu.ready") }
    public static var noFavorites: String { t("menu.noFavorites") }
    public static var openInFinder: String { t("menu.openInFinder") }
    public static var eject: String { t("menu.eject") }
    public static func connectNamed(_ name: String) -> String { t("menu.connectNamed", name) }
    public static func connecting(_ name: String) -> String { t("menu.connecting", name) }
    public static func mounted(_ name: String) -> String { t("menu.mounted", name) }
    public static func ejected(_ name: String) -> String { t("menu.ejected", name) }
    public static func mountedCount(_ count: Int) -> String { t("menu.mountedCount", count) }
    public static var discoveredServers: String { t("menu.discoveredServers") }
    public static var favoritesSettings: String { t("menu.favoritesSettings") }
    public static var diagnostics: String { t("menu.diagnostics") }
    public static var openFSExtensions: String { t("menu.openFSExtensions") }
    public static var quit: String { t("menu.quit") }
    public static var helperMissing: String { t("menu.helperMissing") }
    public static var notMounted: String { t("menu.notMounted") }

    // Diagnostics
    public static var diagnosticsTitle: String { t("diagnostics.title") }
    public static var copy: String { t("diagnostics.copy") }
    public static var save: String { t("diagnostics.save") }
    public static var refresh: String { t("diagnostics.refresh") }

    // Password prompt
    public static func passwordTitle(_ name: String) -> String { t("password.title", name) }
    public static func passwordBody(_ user: String) -> String { t("password.body", user) }
    public static var cancel: String { t("password.cancel") }
}
