import AppKit
import TCCore

/// 更新流程编排：checker 结果 → 更新窗 → installer → 重启/失败提示。
/// 单例由 AppDelegate 首检时创建持有；线程约定 = 恒主线程（checker 回调已 onMain 投递，
/// installer 经本类包装后同样主线程回调）。
final class UpdateFlow {
    private let checker: UpdateChecker
    private let installer: UpdateInstaller
    private let window: UpdateWindowController
    private let store: UpdateStore
    private var installing = false   // 防升级进行中重复触发

    init(checker: UpdateChecker = UpdateChecker(),
         installer: UpdateInstaller = UpdateInstaller(),
         window: UpdateWindowController = .shared,
         store: UpdateStore = .shared) {
        self.checker = checker
        self.installer = installer
        self.window = window
        self.store = store
        window.onUpgrade = { [weak self] in self?.startInstall() }
        window.onSkip = { [weak self] in self?.skipCurrent() }
        window.onRelaunch = { [weak self] in self?.installer.relaunch() }
        // Gatekeeper 指引文本（窗只展示/复制，永不执行——installer 侧红线锁兜底）。
        window.gatekeeperCommandText = installer.gatekeeperCommand
    }

    /// 检查一次（manual=菜单/命令，必给反馈；auto=启动/定时器，仅 available 动作）。
    func check(manual: Bool) {
        guard !installing else { return }
        checker.check(manual: manual) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .available(let m):
                self.pending = m
                self.pendingVersion = m.version
                self.window.presentAvailable(manifest: m, localVersion: self.checker.localVersion)
            case .upToDate:
                if manual { self.alert(L10n.t(.upToDate, self.checker.localVersion)) }
            case .failed:
                if manual { self.alert(L10n.t(.updateFailed)) }
            case .skipped, .throttled:
                break   // 自动路静默
            }
        }
    }

    private var pending: UpdateManifest?
    private var pendingVersion: String?

    #if DEBUG
    /// UITest 夹具：不碰网络直接呈现「发现新版本」态（启动参数 -flyUpdateDemoWindow YES 触发）。
    func presentDemoWindowForTest() {
        let m = UpdateManifest(version: "99.0.0",
                               dmgURL: "https://example.invalid/demo.dmg",
                               sha256: String(repeating: "a", count: 64),
                               notes: "UITest demo")
        pending = m
        pendingVersion = m.version
        window.presentAvailable(manifest: m, localVersion: checker.localVersion)
    }
    #endif

    private func skipCurrent() {
        guard let v = pendingVersion else { return }
        store.skippedVersion = v
    }

    /// 升级执行：installer 的 work 走后台、completion 转主线程（勿动态建队列）。
    private func startInstall() {
        guard let m = pending, !installing else { return }
        installing = true
        window.beginInstalling()
        let work: () -> Void = { [installer, window] in
            installer.install(manifest: m,
                              onPhase: { phase in
                                  DispatchQueue.main.async { window.applyPhase(phase) }
                              },
                              completion: { result in
                                  DispatchQueue.main.async { [weak self] in
                                      self?.installFinished(m.version, result)
                                  }
                              })
        }
        DispatchQueue.global(qos: .utility).async(execute: work)
    }

    private func installFinished(_ version: String, _ result: Result<Void, UpdateInstaller.InstallError>) {
        installing = false
        switch result {
        case .success:
            window.finishSuccess(version: version)
        case .failure:
            window.finishFailure()
            alert(L10n.t(.updateFailed))
        }
    }

    /// 轻量提示（无输入；默认 .warning 样式=代码库现例，缩减 SDK 下不赌其他 style case）。
    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: L10n.t(.okBtn))
        a.runModal()
    }
}
