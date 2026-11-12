import Foundation

public final class BookmarkStore {
    public static let shared = BookmarkStore()

    private let defaults: UserDefaults
    private let key = AppConstants.bookmarksDefaultsKey

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [Bookmark] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []
    }

    public func save(_ bookmarks: [Bookmark]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(data, forKey: key)
        }
    }

    public func upsert(_ bookmark: Bookmark) {
        var all = load()
        if let idx = all.firstIndex(where: { $0.id == bookmark.id }) {
            all[idx] = bookmark
        } else {
            all.append(bookmark)
        }
        save(all)
    }

    public func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }
}
