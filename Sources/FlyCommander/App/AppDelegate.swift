import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = MainWindowController()
        windowController = wc
        if let vc = wc.window?.contentViewController as? MainViewController {
            NSApp.mainMenu = MainMenu.build(target: vc)
        }
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
