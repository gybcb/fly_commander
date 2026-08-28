import Foundation
import TCCore

/// 跨源（含远端）传输执行器（app 层，T6）。
///
/// 主线程调用 run() 后，真正的传输（engine.performCopy/performMove）在后台执行，
/// 主线程不阻塞、UI 不冻结；进度/完成/失败经 state 回调回主线程；传输结束经 onFinished 回主线程刷新窗格。
///
/// 线程边界全部可注入（单测可换同步实现，避免主线程阻塞死锁）：
/// - runInBackground：默认 `DispatchQueue.global(qos: .userInitiated).async`（系统预建队列，
///   **不新建** DispatchQueue——本 SDK 下动态建队会在 async 运行时启动后端错误）。
/// - onMain：默认跳回主线程（已在主线程则直接执行）。
/// - prompt：原样透传给引擎（其线程职责由注入者自己承担；app 侧包装成主线程 NSAlert）。
final class TransferEngine {
    /// 回主线程的进度/状态回调。
    var state: ((OperationState) -> Void)?
    /// 冲突询问，原样传给 OperationEngine。
    var prompt: ConflictPrompt?
    /// 传输结束（无论成败）回主线程的收尾（刷新窗格等），带源/目标窗格。
    var onFinished: ((_ srcPane: FilePane, _ dstPane: FilePane) -> Void)?

    /// 后台执行器（单测可换同步实现）。
    var runInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// 回主线程执行器（单测可换同步实现）。
    var onMain: (@escaping () -> Void) -> Void = {
        if Thread.isMainThread { $0() } else { DispatchQueue.main.async(execute: $0) }
    }

    let engine: OperationEngine

    init(engine: OperationEngine = OperationEngine()) {
        self.engine = engine
    }

    /// 把任意 ConflictPrompt 提升到主线程执行（后台线程 sync 回主线程）。
    /// 引擎只在 runInBackground 块内调用 prompt（后台线程）；已在主线程则直行，
    /// 单测注入同步 runInBackground 时不会自锁。
    static func promptOnMain(_ raw: @escaping ConflictPrompt) -> ConflictPrompt {
        { s, d in
            if Thread.isMainThread { return raw(s, d) }
            return DispatchQueue.main.sync { raw(s, d) }
        }
    }

    /// 复制/移动活动窗格标记项到另一窗格。targets 为空则直接返回。
    func run(_ isCopy: Bool, _ srcPane: FilePane, _ dstPane: FilePane) {
        let targets = srcPane.operationTargets
        guard !targets.isEmpty else { return }
        let label = (isCopy ? "复制" : "移动") + " \(targets.count) 个文件"
        let srcSource = srcPane.source
        let dstSource = dstPane.source
        let dstDir = dstPane.path
        let prompt = self.prompt
        let engine = self.engine
        let state = self.state
        let onMain = self.onMain

        runInBackground {
            onMain { state?(.running(label: label, progress: 0)) }
            var warnings: [String] = []
            do {
                if isCopy {
                    try engine.performCopy(targets, to: dstDir, srcSource: srcSource, dstSource: dstSource,
                                            prompt: prompt) { d, c in
                        onMain { state?(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c))) }
                    }
                } else {
                    try engine.performMove(targets, to: dstDir, srcSource: srcSource, dstSource: dstSource,
                                            prompt: prompt,
                                            progress: { d, c in
                        onMain { state?(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c))) }
                    },
                                            onWarning: { warnings.append($0) })
                }
                let note = warnings.isEmpty ? "" : "　⚠ \(warnings.joined(separator: "；"))"
                onMain { state?(.done("\(label) 完成\(note)")) }
            } catch let e as TCError {
                onMain { state?(e == .cancelled ? .idle : .failed(e.message)) }
            } catch {
                onMain { state?(.failed(error.localizedDescription)) }
            }
            onMain { self.onFinished?(srcPane, dstPane) }
        }
    }
}
