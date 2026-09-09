import AppKit
import Foundation
import TCCore

#if DEBUG
/// **仅 UI 测试**（`FLY_UI_DEMO=crossCopy`）：把右窗格换成一个 isRemote 的本地夹具源，
/// 触发 router 的远端传输分支 → onRemoteTransfer → 真进度面板 + 真取消旗。
///
/// 为什么需要它：进度面板只在任一端 `isRemote` 时挂上（CommandRouter.handleTransfer），
/// 而两个本地窗格共享 sourceID "local" 恒走同步快路径、永不上屏。XCUITest 里跑真
/// SFTP（in-app sshd）成本与 flaky 都过高，故用一个"假远端真本地"的源把跨源 pump 路径
/// 拉出来：源 openReader/streamWrite 都读写真实临时目录 → 字节进度真实、取消真实生效，
/// 面板显示的百分比/明细/路由都是生产代码算出来的，测试只断言"窗口出现 / 点按钮消失"。
///
/// 隔离：整个文件 #if DEBUG，Release 产物不含；sourceID 带 "uicross" 前缀 + port 2222
/// 与真 sftp 连接串彻底区分。仅显式 FLY_UI_DEMO=crossCopy 时激活，其余启动零影响。
final class UIRemoteFileSource: NSObject, FileSource {
    let root: URL
    let sourceID: String
    var perReadDelay: UInt32 = 0   // 每块微秒休眠：拉长传输让 XCUITest 来得及点取消
    private let local = LocalFileSource()

    init(root: URL, sourceID: String) {
        self.root = root
        self.sourceID = sourceID
    }

    var isRemote: Bool { true }          // 骗 router 走 onRemoteTransfer
    var supportsTransfer: Bool { true }

    // 假远端与本地夹具共用同一绝对目录树：TCPath 直接透传（setSource 传的就是
    // TCPath(root.path)，窗格内部拼接始终绝对）。
    private func toLocal(_ path: TCPath) -> TCPath { path }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        try local.listDirectory(toLocal(path))
    }
    func isDirectory(_ path: TCPath) -> Bool { local.isDirectory(toLocal(path)) }
    func stat(_ path: TCPath) throws -> FileItem? { try local.stat(toLocal(path)) }
    func copyItem(from: TCPath, to: TCPath) throws {
        try local.copyItem(from: toLocal(from), to: toLocal(to))
    }
    func moveItem(from: TCPath, to: TCPath) throws {
        try local.moveItem(from: toLocal(from), to: toLocal(to))
    }
    func renameItem(at: TCPath, to: TCPath) throws {
        try local.renameItem(at: toLocal(at), to: toLocal(to))
    }
    func makeDirectory(at path: TCPath) throws { try local.makeDirectory(at: toLocal(path)) }
    func removeItem(at path: TCPath) throws { try local.removeItem(at: toLocal(path)) }

    func openReader(_ path: TCPath) throws -> ReadHandle {
        try local.openReader(toLocal(path))
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?,
                     write: @escaping () throws -> Data) throws {
        // 假远端=写入端（demo 复制方向 left→right）。每块拖慢：本机 pump 太快，
        // XCUITest 会来不及在传输中点取消；3ms/64KB ≈ 20MB/s 上限，够肉眼窗口。
        let delay = perReadDelay
        try local.streamWrite(toLocal(path), totalBytes: totalBytes) {
            if delay > 0 { usleep(delay) }
            return try write()
        }
    }
}

extension MainViewController {
    /// loadView 末尾调用：命中 FLY_UI_DEMO=crossCopy 时改右窗格源并起一次跨源复制。
    /// FLY_UI_DEMO_DIR = 目标目录（左窗格仍指向 FLY_START_DIR 源目录）。
    @objc func maybeStartUICrossCopyDemo() {
        guard ProcessInfo.processInfo.environment["FLY_UI_DEMO"] == "crossCopy" else { return }
        guard let dir = ProcessInfo.processInfo.environment["FLY_UI_DEMO_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        // 右窗格 = 假远端（独立 sourceID，根=目标目录），左窗格仍本地（源目录）
        // → sourceID 不等 → 跨源 pump。
        let fake = UIRemoteFileSource(root: root, sourceID: "sftp://uicross:2222")
        // 每 64KB 块毫秒数：取消用例拉大（传输可点窗口），完成用例置 0（快）。
        let delayMs = Int(ProcessInfo.processInfo.environment["FLY_UI_DEMO_DELAYMS"] ?? "") ?? 5
        fake.perReadDelay = UInt32(max(0, delayMs)) * 1000
        workspace.rightTabs.activePane.setSource(fake, andPath: TCPath(root.path))
        // 左窗格全选 → 复制（active=left 默认）→ handleTransfer 见右端 isRemote → 面板。
        workspace.leftTabs.activePane.selectAll()
        router.execute(.copy)
    }
}
#endif
