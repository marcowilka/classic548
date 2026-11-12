import AppKit
import Foundation

/// Open ClassicAFP volumes in Finder.
///
/// Do not use `LSSharedFileList*` — it is deprecated since 10.11 and crashes
/// with EXC_BAD_ACCESS on current macOS when inserting Favorite Volumes.
public enum FinderAccess {
    /// Opens a Finder window rooted at the mount (not just Desktop selection).
    public static func revealVolume(at url: URL) {
        let ok = NSWorkspace.shared.open(url)
        if !ok {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
        DiagnosticsLog.shared.info("Finder reveal \(url.path) open=\(ok)")
    }
}
