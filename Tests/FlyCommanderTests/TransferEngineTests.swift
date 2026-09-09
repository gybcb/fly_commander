import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T6 单测：TransferEngine 后台跨源传输的状态回调、收尾刷新、冲突询问透传。
/// 线程边界注入同步实现（runInBackground/onMain 直接调用），避免主线程死锁。

/// 内存假源：table 存元数据，data 存文件内容（跨源流式写落这里）。
private final class MemSource: FileSource {
    let sourceID: String
    var isRemote: Bool
    var supportsTransfer = true
    var table: [String: FileItem] = [:]
    var data: [String: Data] = [:]
    var removeError: TCError?
    var removeCalls: [String] = []
    var dirItems: [FileItem] = []

    init(id: String, remote: Bool) { sourceID = id; isRemote = remote }

    func item(_ path: String, size: Int64) -> FileItem {
        FileItem(id: path, path: TCPath(path), name: (path as NSString).lastPathComponent,
                 isDirectory: false, size: size, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirItems }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? { table[path.pathString] }
    func copyItem(from: TCPath, to: TCPath) throws {
        table[to.pathString] = table[from.pathString]
        data[to.pathString] = data[from.pathString]
    }
    func moveItem(from: TCPath, to: TCPath) throws {
        table[to.pathString] = table.removeValue(forKey: from.pathString)
        data[to.pathString] = data.removeValue(forKey: from.pathString)
    }
    func renameItem(at: TCPath, to: TCPath) throws {
        table[to.pathString] = table.removeValue(forKey: at.pathString)
        data[to.pathString] = data.removeValue(forKey: at.pathString)
    }
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {
        removeCalls.append(at.pathString)
        if let e = removeError { throw e }
        table[at.pathString] = nil
        data[at.pathString] = nil
    }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        guard let payload = data[path.pathString] else { throw TCError.unknown("no file: \(path.pathString)") }
        var i = 0
        return { _ in
            guard i < payload.count else { return Data() }
            let slice = payload.subdata(in: i..<min(i + 7, payload.count))
            i += slice.count
            return slice
        }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {
        var buf = Data()
        while true {
            let chunk = try write()
            if chunk.isEmpty { break }
            buf.append(chunk)
        }
        data[path.pathString] = buf
        table[path.pathString] = item(path.pathString, size: Int64(buf.count))
    }
}

/// 状态记录器（引用类型，闭包与测试共享同一份数组）。
/// Plan B：OperationState 是结构化契约（key + args + warningLines），原样存下再逐 case 断言。
private final class StateRecorder {
    var entries: [OperationState] = []
    var finishedPanes: (FilePane, FilePane)?
    func record(_ s: OperationState) { entries.append(s) }
}

/// 同步线程边界的执行器 + 真实 FilePane 对（左=远端假源，右=本地假源）。
private final class Harness {
    let engine: TransferEngine
    let remote: MemSource
    let local: MemSource
    let left: FilePane
    let right: FilePane
    let rec = StateRecorder()

    init() {
        remote = MemSource(id: "sftp://h:2222", remote: true)
        local = MemSource(id: "local-t", remote: false)
        let aFile = remote.item("/src/a.txt", size: 11)
        remote.table["/src/a.txt"] = aFile
        remote.data["/src/a.txt"] = Data("hello world".utf8)
        remote.dirItems = [aFile]

        left = FilePane(id: .left, source: remote, startPath: TCPath("/src"))
        right = FilePane(id: .right, source: local, startPath: TCPath("/dst"))
        left.load()
        right.load()

        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        engine = te
        te.state = { [weak self] s in self?.rec.record(s) }
        te.onFinished = { [weak self] s, d in self?.rec.finishedPanes = (s, d) }
    }
}

final class TransferEngineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 警告串/状态串都经 L10n 表；固定英文默认，zh 用例内部自切自恢复。
        L10n.current = .en
    }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    func testCrossSourceCopyStreamsAndEmitsProgressAndDone() {
        let h = Harness()
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
        XCTAssertEqual(h.local.table["/dst/a.txt"]?.size, 11)
        // 状态序：running(0) → running(1) → done（Plan B：结构化 key，非中文串）
        XCTAssertEqual(h.rec.entries.count, 3, "状态流：\(h.rec.entries)")
        XCTAssertEqual(h.rec.entries[0], .running(label: .opCopying, args: ["1"], progress: 0))
        XCTAssertEqual(h.rec.entries[1], .running(label: .opCopying, args: ["1"], progress: 1))
        XCTAssertEqual(h.rec.entries[2], .done(label: .opCopying, args: ["1"], warningLines: []))
    }

    func testOnFinishedReceivesBothPanes() {
        let h = Harness()
        h.engine.run(true, h.left, h.right)
        XCTAssertTrue(h.rec.finishedPanes?.0 === h.left, "onFinished 源窗格应是 left")
        XCTAssertTrue(h.rec.finishedPanes?.1 === h.right, "onFinished 目标窗格应是 right")
    }

    func testConflictPromptIsPassedThrough() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        h.local.data["/dst/a.txt"] = Data("old".utf8)
        var prompts: [(String, String)] = []
        h.engine.prompt = { s, d in
            prompts.append((s.pathString, d.pathString))
            return .overwrite
        }
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].0, "/src/a.txt")
        XCTAssertEqual(prompts[0].1, "/dst/a.txt")
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8), "覆盖后应为源内容")
    }

    func testConflictPromptRunsOnMainThread() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        var ranOnMain = false
        h.engine.prompt = TransferEngine.promptOnMain { _, _ in
            ranOnMain = Thread.isMainThread
            return .overwrite
        }
        // 模拟 app 侧真实线程拓扑：传输块跑在后台线程（run() 仍在主线程发起）。
        // 用 expectation + wait(for:)（泵 run loop），不能用信号量阻塞主线程——
        // 否则 promptOnMain 的 main.sync 无法被服务。
        let exp = expectation(description: "transfer finished")
        h.engine.runInBackground = { block in
            DispatchQueue.global(qos: .userInitiated).async {
                block()
                exp.fulfill()
            }
        }
        h.engine.onMain = { $0() }
        h.engine.run(true, h.left, h.right)
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(ranOnMain, "冲突询问必须在主线程执行")
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
    }

    func testCancelFromPromptYieldsIdleNotFailed() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        h.engine.prompt = { _, _ in .cancel }
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.rec.entries.last, .idle, "取消应是 idle：\(h.rec.entries)")
    }

    func testSourceDeleteFailureOnMoveWarnsButCompletes() {
        let h = Harness()
        h.remote.removeError = TCError.busy("x")
        h.engine.run(false, h.left, h.right)
        // Plan B：引擎产结构化原料 (name, TCError)，成品警告串在 AppKit 边界（L10n）组装。
        guard case .done(let label, let args, let warns)? = h.rec.entries.last else {
            return XCTFail("move 应完成：\(h.rec.entries)")
        }
        XCTAssertEqual(label, .opMoving)
        XCTAssertEqual(args, ["1"])
        XCTAssertEqual(warns, ["Source leftover: a.txt (Busy: x)"], "警告成品串：\(warns)")
        // 传输本身成功
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
    }

    /// 警告串随语言：zh 下 TransferEngine 组装的是中文模板（全角 ：（））。
    func testSourceDeleteWarningFollowsLanguage() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let h = Harness()
        h.remote.removeError = TCError.busy("x")
        h.engine.run(false, h.left, h.right)
        guard case .done(_, _, let warns)? = h.rec.entries.last else {
            return XCTFail("move 应完成：\(h.rec.entries)")
        }
        XCTAssertEqual(warns, ["源端残留：a.txt（忙碌/被占用：x）"], "zh 警告：\(warns)")
    }

    /// R-C1 哨兵：警告原料是 `.unknown`（locale 透传文本）时，内嵌串必须是**裸 payload**——
    /// errUnknown 模板改裸 {0} 后不得再出现 "（错误：disk full）" 的层内前缀。
    func testSourceDeleteWarningWithUnknownIsBarePayload() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let h = Harness()
        h.remote.removeError = TCError.unknown("disk full")
        h.engine.run(false, h.left, h.right)
        guard case .done(_, _, let warns)? = h.rec.entries.last else {
            return XCTFail("move 应完成：\(h.rec.entries)")
        }
        XCTAssertEqual(warns, ["源端残留：a.txt（disk full）"], "zh 警告：\(warns)")
    }

    func testEngineFailureSurfacesFailedState() {
        let h = Harness()
        h.remote.data = [:]   // openReader 抛 TCError.unknown("no file: /src/a.txt")
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.rec.entries.last, .failed(.unknown("no file: /src/a.txt")),
                       "应透出源端错误（结构化 TCError）：\(h.rec.entries)")
    }

    func testNoTargetsDoesNothing() {
        let h = Harness()
        h.remote.dirItems = []
        h.left.load()
        h.engine.run(true, h.left, h.right)
        XCTAssertTrue(h.rec.entries.isEmpty, "无目标项时不应有任何状态回调：\(h.rec.entries)")
    }

    // MARK: - T2：cancel / onProgress 透传

    /// cancel 置位后引擎应抛 .cancelled → 状态流终态为 .idle（T1 已定稿的 cancelled→idle 路径）。
    func testCancelPropagatesToIdle() {
        let h = Harness()
        let cancel = CancelFlag()
        var progressCount = 0
        h.engine.run(true, h.left, h.right, cancel: cancel) { _ in
            progressCount += 1
            cancel.cancel()  // 第一次进度回调即请求取消
        }
        XCTAssertEqual(h.rec.entries.last, .idle, "cancel 后应报 idle：\(h.rec.entries)")
        XCTAssertGreaterThan(progressCount, 0, "cancel 前应至少收到一次 onProgress")
    }

    /// onProgress 帧形：跨源泵 + 冻结时钟 → 恰 [字节帧, 文件帧] 两帧。
    /// 字节帧 name=""/fileDone=0（文件未完成）；文件帧携完成名、bytesDone=nil、非 SFTP route=nil。
    /// 变异：文件帧 name 写死 "" / 字节帧误带 bytesDone=nil → 红。
    func testOnProgressReportsFileProgress() {
        let h = Harness()
        h.engine.progressClock = { 5 }   // 冻结：3 次引擎字节调用只剩哨兵首帧
        var infos: [TransferEngine.TransferProgressInfo] = []
        h.engine.run(true, h.left, h.right, cancel: CancelFlag()) { infos.append($0) }
        XCTAssertEqual(infos.count, 2, "冻结时钟下 1 字节帧 + 1 文件帧：\(infos.map { "\($0.name):\($0.bytesDone ?? -1)" })")
        XCTAssertEqual(infos[0].bytesDone, 7, "字节帧 = 首 chunk 累计")
        XCTAssertEqual(infos[0].name, "", "字节帧 name 恒空串（UI 保留上一帧）")
        XCTAssertEqual(infos[0].fileDone, 0, "字节帧先于任何文件完成")
        XCTAssertNil(infos[1].bytesDone, "文件帧不带字节字段")
        XCTAssertEqual(infos[1].name, "a.txt", "文件帧携完成文件名")
        XCTAssertEqual(infos[1].fileDone, 1)
        XCTAssertEqual(infos[1].fileTotal, 1)
        XCTAssertNil(infos[1].route, "MemSource 非 SFTP 源，route 恒 nil")
        XCTAssertEqual(h.rec.entries.last, .done(label: .opCopying, args: ["1"], warningLines: []))
    }

    // MARK: - T2：传输源替换（独立第二连接的应用层替身）

    /// 替身假源：MemSource 面 + 调用计数，验证传输 IO 落在替身、浏览源零染指。
    private final class SubSource: FileSource {
        let sourceID: String
        var isRemote = true
        var supportsTransfer = true
        var table: [String: FileItem] = [:]
        var data: [String: Data] = [:]
        var copyCalls = 0, streamWrites = 0, openReaders = 0
        var openReaderError: TCError?   // 非 nil → openReader 抛错（模拟传输中途连接断）

        init(id: String) { sourceID = id }
        func item(_ path: String, size: Int64) -> FileItem {
            FileItem(id: path, path: TCPath(path), name: (path as NSString).lastPathComponent,
                     isDirectory: false, size: size, modificationDate: .distantPast,
                     isHidden: false, isReadOnly: false, isExecutable: false)
        }
        func listDirectory(_ path: TCPath) throws -> [FileItem] { [] }
        func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
        func stat(_ path: TCPath) throws -> FileItem? { table[path.pathString] }
        func copyItem(from: TCPath, to: TCPath) throws {
            copyCalls += 1
            table[to.pathString] = table[from.pathString]
            data[to.pathString] = data[from.pathString]
        }
        func moveItem(from: TCPath, to: TCPath) throws { try copyItem(from: from, to: to) }
        func renameItem(at: TCPath, to: TCPath) throws { try copyItem(from: at, to: to) }
        func makeDirectory(at: TCPath) throws {}
        func removeItem(at: TCPath) throws {}
        func openReader(_ path: TCPath) throws -> ReadHandle {
            openReaders += 1
            if let e = openReaderError { throw e }
            let payload = data[path.pathString] ?? Data()
            var i = 0
            return { _ in
                guard i < payload.count else { return nil }
                let slice = payload.subdata(in: i..<min(i + 7, payload.count))
                i += slice.count
                return slice
            }
        }
        func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {
            streamWrites += 1
            var buf = Data()
            while true {
                let chunk = try write()
                if chunk.isEmpty { break }
                buf.append(chunk)
            }
            data[path.pathString] = buf
        }
    }

    /// 同源双窗格 + provider → 两端共用**同一条**替身（一次握手），传输 IO 全落替身，
    /// 浏览源零调用，收尾恰一次。
    /// 变异：同源分支若给 dst 另开一条（provider 调两次）→ calls==1 红；
    ///       若 cleanups 重复登记 → cleans==1 红；若未替换 → 浏览源 copyCalls>0 红。
    func testSameSourceSubstitutionSharesOneConnection() {
        let h = Harness()
        let browse = h.remote
        // 左右窗格都挂"远端"假浏览源（sourceID 相同 = 同源双窗格现场）。
        let right = FilePane(id: .right, source: browse, startPath: TCPath("/dst"))
        right.load()

        // provider 恒返回**同一实例**（模拟 ConnectionStore 的同源单连接），预置可拷内容。
        let sub = SubSource(id: "sftp://h:2222")
        sub.table["/src/a.txt"] = sub.item("/src/a.txt", size: 11)
        sub.data["/src/a.txt"] = Data("hello world".utf8)
        var calls = 0, cleans = 0
        h.engine.transferSourceProvider = { _ in
            calls += 1
            return (sub, { cleans += 1 })
        }
        h.engine.run(true, h.left, right, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(calls, 1, "同源只应开一条替身连接")
        XCTAssertEqual(cleans, 1, "收尾清理恰一次")
        XCTAssertEqual(sub.copyCalls, 1, "cp 快路径应落在替身")
        XCTAssertEqual(sub.data["/dst/a.txt"], Data("hello world".utf8))
        XCTAssertTrue(browse.removeCalls.isEmpty && browse.data["/dst/a.txt"] == nil,
                      "浏览源不得承接传输 IO")
    }

    /// 跨服务器：两端各开一条独立替身，各清理一次。
    /// 变异：dst 分支被删 → calls==2 红。
    func testCrossServerSubstitutionOpensTwo() {
        let h = Harness()
        var calls = 0, cleans = 0
        h.engine.transferSourceProvider = { _ in
            calls += 1
            let sub = SubSource(id: "sftp://x\(calls)")
            return (sub, { cleans += 1 })
        }
        h.engine.run(true, h.left, h.right, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(calls, 2, "跨服务器两端各一条")
        XCTAssertEqual(cleans, 2)
    }

    /// provider 返回 nil（取不到 secret / 建连失败）→ 回落共享浏览源 = 现状行为。
    /// 变异：nil 分支若硬造替身 → 浏览源 copy 计数红。
    func testSubstitutionFallsBackToSharedSource() {
        let h = Harness()
        h.engine.transferSourceProvider = { _ in nil }
        h.engine.run(true, h.left, h.right, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8),
                       "回落路径下传输照常完成（走原浏览源）")
    }

    /// 传输失败也要清理（错误路径不泄漏连接）。跨服务器对（remote→local）两端各替换一次。
    /// 变异：清理挪到 do-success 分支内 → cleans==0 红。
    func testSubstitutionCleanedUpOnFailure() {
        let h = Harness()
        let failing = SubSource(id: "sftp://h:2222")
        failing.openReaderError = TCError.sftpConnectFailed   // 传输中途"连接断"
        var cleans = 0
        h.engine.transferSourceProvider = { browse in
            browse.isRemote ? (failing, { cleans += 1 }) : nil   // 只换远端一侧
        }
        h.engine.run(true, h.left, h.right, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(cleans, 1, "失败也必须关闭临时连接")
        XCTAssertEqual(h.rec.entries.last?.isFailed, true, "应报 failed：\(h.rec.entries)")
    }

    // MARK: - T2：字节节流（注入假时钟）

    /// 假时钟按脚本吐值（0 / 0.06 / 0.12），均越过 50ms 间隔 → 引擎 3 次字节调用全报。
    /// （11B / 7B chunk = 字节调用 (7,11) (11,11) + 尾空 chunk 帧 (11,11)——T1 已钉死。）
    /// 变异：判定取反（>= 改 <）→ 帧被吞，计数红。
    func testByteThrottleReportsWhenIntervalElapsed() {
        let h = Harness()
        var times: [TimeInterval] = [0, 0.06, 0.12, 0.2, 0.3, 0.4, 0.5]
        h.engine.progressClock = { times.isEmpty ? 100 : times.removeFirst() }
        var byteFrames = 0
        h.engine.run(true, h.left, h.right, cancel: CancelFlag()) { info in
            if info.bytesDone != nil { byteFrames += 1 }
        }
        XCTAssertEqual(byteFrames, 3, "3 次引擎字节调用间隔均 ≥50ms → 全报：\(byteFrames)")
    }

    /// 同刻连发：首帧必达（初值哨兵），其余全吞——节流真在吞，不是全放。
    /// 变异：删掉 shouldReportByte（恒 true）→ 5 帧红。
    func testByteThrottleSwallowsBurstAtSameInstant() {
        let h = Harness()
        h.engine.progressClock = { 5 }   // 时钟冻结
        var byteFrames = 0
        h.engine.run(true, h.left, h.right, cancel: CancelFlag()) { info in
            if info.bytesDone != nil { byteFrames += 1 }
        }
        XCTAssertEqual(byteFrames, 1, "冻结时钟下只放行哨兵后的首帧")
    }

    /// 文件完成后节流重置：下一文件的**首个**字节帧立即可报（哪怕同刻）。
    /// 冻结时钟（恒 5）下：每文件各报 1 首帧；若无文件边界重置，b.txt 帧被同刻吞掉 → 总 1。
    /// 变异：删掉 fileProgress 里的 lastByteReportTime 重置 → byteFrames==1，红。
    func testThrottleResetsAtFileBoundary() {
        let h = Harness()
        let b = h.remote.item("/src/b.txt", size: 7)
        h.remote.table["/src/b.txt"] = b
        h.remote.data["/src/b.txt"] = Data("bbbbbbb".utf8)   // 单 chunk
        h.remote.dirItems.append(b)
        h.left.load()
        h.left.selectAll()   // 两文件都进操作目标
        h.engine.progressClock = { 5 }   // 冻结：不重置则第二文件字节帧全被吞
        var byteFrames = 0, fileFrames = 0
        h.engine.run(true, h.left, h.right, cancel: CancelFlag()) { info in
            if info.bytesDone != nil { byteFrames += 1 } else { fileFrames += 1 }
        }
        XCTAssertEqual(fileFrames, 2, "两个文件各一次文件级帧")
        XCTAssertEqual(byteFrames, 2, "每文件各 1 首帧（重置生效），同刻其余吞掉：\(byteFrames)")
    }

    /// 文件帧 name=完成文件名；字节帧 name=""（UI 保留上一帧）。
    /// 变异：文件帧 name 写死 "" 或字节帧 name 塞文件名 → 红。
    func testFileAndByteFrameFields() {
        let h = Harness()
        h.remote.data["/src/a.txt"] = Data("hello world again".utf8)   // 19B → 3 chunk
        h.remote.table["/src/a.txt"] = h.remote.item("/src/a.txt", size: 19)
        h.engine.progressClock = { 5 }   // 冻结：字节帧只首帧（哨兵放行）
        var fileNames: [String] = []
        var byteNames: [String] = []
        h.engine.run(true, h.left, h.right, cancel: CancelFlag()) { info in
            if info.bytesDone == nil { fileNames.append(info.name) } else { byteNames.append(info.name) }
        }
        XCTAssertEqual(fileNames, ["a.txt"], "文件帧携完成文件名")
        XCTAssertEqual(byteNames, [""], "字节帧 name 恒空串（UI 保留上一帧）")
    }

    // MARK: - T2：速度估算（纯函数）

    func testSpeedNilWhenTooFewSamples() {
        XCTAssertNil(TransferSpeed.estimate(samples: []))
        XCTAssertNil(TransferSpeed.estimate(samples: [(0, 100)]))
    }

    func testSpeedNilWhenWindowTooShort() {
        // 跨度 0.1s < minWindow 0.5s → 宁缺毋假。
        XCTAssertNil(TransferSpeed.estimate(samples: [(0, 0), (0.1, 1000)]))
    }

    func testSpeedWindowAverage() {
        // 尾窗口 = (0.5, 500) → (1.0, 1500)：1000B / 0.5s = 2000B/s。
        let v = TransferSpeed.estimate(samples: [(0, 0), (0.5, 500), (1.0, 1500)])
        XCTAssertEqual(v!, 2000, accuracy: 1e-9, "取 ≥minWindow 的最小尾窗口")
    }

    func testSpeedNilOnNegativeDelta() {
        // 累计字节倒退（重置）→ 不给负速度。
        XCTAssertNil(TransferSpeed.estimate(samples: [(0, 1000), (1.0, 500)]))
    }
}

private extension OperationState {
    var isFailed: Bool { if case .failed = self { return true }; return false }
}
