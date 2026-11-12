import AppKit

final class DiagnosticsWindowController: NSWindowController {
    private let textView = NSTextView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.diagnosticsTitle
        window.center()
        self.init(window: window)

        let root = NSView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 48, width: 696, height: 360))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width, .height]
        scroll.documentView = textView
        root.addSubview(scroll)

        let copyButton = NSButton(title: L10n.copy, target: self, action: #selector(copyLog))
        copyButton.frame = NSRect(x: 12, y: 12, width: 80, height: 28)
        root.addSubview(copyButton)

        let saveButton = NSButton(title: L10n.save, target: self, action: #selector(saveLog))
        saveButton.frame = NSRect(x: 100, y: 12, width: 80, height: 28)
        root.addSubview(saveButton)

        let refreshButton = NSButton(title: L10n.refresh, target: self, action: #selector(refresh))
        refreshButton.frame = NSRect(x: 188, y: 12, width: 90, height: 28)
        root.addSubview(refreshButton)

        window.contentView = root
        DiagnosticsLog.shared.onChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    @objc private func refresh() {
        textView.string = DiagnosticsLog.shared.snapshot()
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsLog.shared.snapshot(), forType: .string)
    }

    @objc private func saveLog() {
        do {
            let url = try DiagnosticsLog.shared.persistToDisk()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
