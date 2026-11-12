import Foundation
import FSKit

final class AFPItem: FSItem {
    let path: String
    let name: String
    var itemType: FSItem.ItemType
    var fileID: FSItem.Identifier
    var parentID: FSItem.Identifier
    var size: UInt64
    var mode: mode_t
    var mtime: Date
    var openFileID: UInt32?

    init(
        path: String,
        name: String,
        itemType: FSItem.ItemType,
        fileID: FSItem.Identifier,
        parentID: FSItem.Identifier,
        size: UInt64 = 0,
        mode: mode_t = 0o644,
        mtime: Date = Date()
    ) {
        self.path = path
        self.name = name
        self.itemType = itemType
        self.fileID = fileID
        self.parentID = parentID
        self.size = size
        self.mode = mode
        self.mtime = mtime
        super.init()
    }

    static func root() -> AFPItem {
        AFPItem(
            path: "/",
            name: "/",
            itemType: .directory,
            fileID: .rootDirectory,
            parentID: .parentOfRoot,
            mode: 0o755
        )
    }
}
