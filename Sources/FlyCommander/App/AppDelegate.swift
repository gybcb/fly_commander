import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private weak var mainViewController: MainViewController?
    private var activeObserver: NSObjectProtocol?
    /// 24h 复检计时器（持强引用随 delegate 终身；启动首检走 asyncAfter 不占它）。
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App icon：xcassets 编译后系统自动加载 AppIcon；SPM 构建走 Bundle 资源兜底。
        if NSApp.applicationIconImage == nil
           || NSApp.applicationIconImage?.size == NSSize(width: 0, height: 0) {
            if let icon = NSImage(named: "AppIcon") {
                NSApp.applicationIconImage = icon
            }
        }
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
            vc.attachMainWindowController(wc)   // 语言切换时重刷工具栏 label（VC 侧 weak）
            mainViewController = vc
        }
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 回收上次残留的 /Volumes/FlyCommander/* 挂载（后台跑，不阻塞启动窗；
        // 读取 mount 表→逐个静默 umount，无残留时 no-op）。
        DispatchQueue.global(qos: .utility).async { SMBMountManager().reclaimStale() }
        // 自动刷新兜底：回到前台时补刷**已注册流**的窗格（只碰本地 fileURL 目录，
        // 不扩 SFTP/SMB 面，守用户裁决）。兜 FSEvents 队列 overflow 丢事件与
        // 「目录被删后重建」的失联窗口。observer 持强引用随 delegate 终身（单例生命周期）。
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.mainViewController?.directoryWatcher.refreshAllWatched()
        }
        #if DEBUG
        // UITest 夹具：启动参数呈现假更新窗（不联网；断言窗标题/按钮 AX 可达）。
        if UserDefaults.standard.bool(forKey: "flyUpdateDemoWindow") {
            mainViewController?.updateFlow.presentDemoWindowForTest()
        }
        #endif
        // 版本自动检查（仅真实运行；UI 测试模式下抑制——防测试期联网/弹窗）。
        // 启动延迟 10s 首检（不抢启动路径），之后每 24h 复检（App 常驻也能收到）。
        guard !TestIsolation.suppressPreferenceWrites else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.mainViewController?.updateFlow.check(manual: false)
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: UpdateChecker.checkInterval,
                                           repeats: true) { [weak self] _ in
            self?.mainViewController?.updateFlow.check(manual: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
