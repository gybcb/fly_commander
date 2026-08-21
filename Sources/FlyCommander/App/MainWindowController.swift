import AppKit

final class MainWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FlyCommander"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.contentViewController = MainViewController()
        self.init(window: window)
        window.center()
    }
}
