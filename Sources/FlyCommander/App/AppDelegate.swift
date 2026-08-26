import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 全局关掉 macOS 原生 window tabbing。真正让 Ctrl+Tab / Ctrl+Shift+Tab 落到
        // 我们自己的 TC 式标签切换的是 FlyWindow.sendEvent 的拦截——本 SDK（Xcode 26.6 /
        // macOS 26）下 allowsAutomaticWindowTabbing 与 window.tabbingMode 对 ⌃⇥ 的
        // key binding 均无效（已 probe 实证，详见项目记忆 reduced-sdk）。此处为意图声明
        // 兼双保险（防原生 tabbing 的其他副作用，如窗口自动合并）。
        NSWindow.allowsAutomaticWindowTabbing = false
        let wc = MainWindowController()
        windowController = wc
        if let vc = wc.window?.contentViewController as? MainViewController {
            NSApp.mainMenu = MainMenu.build(target: vc)
        }
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 回收上次残留的 /Volumes/FlyCommander/* 挂载（后台跑，不阻塞启动窗；
        // 读取 mount 表→逐个静默 umount，无残留时 no-op）。
        DispatchQueue.global(qos: .utility).async { SMBMountManager().reclaimStale() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
