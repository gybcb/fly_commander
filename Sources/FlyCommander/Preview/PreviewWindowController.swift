import AppKit
import TCCore

final class PreviewWindowController: NSWindowController {
    private static let shared = PreviewWindowController()

    static func show(item: FileItem) {
        shared.present(item: item)
    }

    private var hasBeenShown = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.title = L10n.t(.previewWindowTitlePlain)
        window.contentViewController = PreviewViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func present(item: FileItem) {
        window?.title = L10n.t(.previewWindowTitle, item.name)
        (window?.contentViewController as? PreviewViewController)?.show(item: item)
        if !hasBeenShown {
            hasBeenShown = true
            window?.center()
        } else if window?.isVisible == false {
            let frame = window!.frame
            window?.setFrameOrigin(NSPoint(x: frame.origin.x + 48, y: frame.origin.y + 48))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
