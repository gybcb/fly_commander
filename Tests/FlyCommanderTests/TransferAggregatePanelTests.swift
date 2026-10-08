import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 全进度（聚合通道）消费侧合同锁（spec §5 锁 8/9）。
///
/// 背景（用户报障）：拷目录时条/速度只反映当前单文件。修法 = 引擎预扫描账本
/// 产 aggregate 帧 → TransferEngine 帧管线（锁 8）→ 面板 overall 优先（锁 9）。
/// 面板既有单文件测试（TransferProgressPanelTests / TransferPanelDirectRouteTests）
/// = overall 恒 nil 的回退分支回归锁，本文件不重复其断言。
final class TransferAggregatePanelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.current = .en
        TransferProgressWindowController.resetSharedForTest()
    }
    override func tearDown() {
        TransferProgressWindowController.resetSharedForTest()
        L10n.current = .en
        super.tearDown()
    }

    // MARK: - 锁 8：TransferEngine 帧管线

    private final class MemSrc: FileSource {
        let sourceID: String
        var isRemote: Bool
        var supportsTransfer = true
        var table: [String: FileItem] = [:]
        var data: [String: Data] = [:]
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
        func copyItem(from: TCPath, to: TCPath) throws {}
        func moveItem(from: TCPath, to: TCPath) throws {}
        func renameItem(at: TCPath, to: TCPath) throws {}
        func makeDirectory(at: TCPath) throws {}
        func removeItem(at: TCPath) throws {}
        func openReader(_ path: TCPath) throws -> ReadHandle {
            guard let payload = data[path.pathString] else { throw TCError.unknown("no file") }
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

    /// 两文件（14+14 字节）跨源拷贝 → onProgress 必须出现携 overall 的帧，
    /// overall total = 预扫描和 28（修复前 TransferProgressInfo 无此字段 = 编译红）。
    func testRunEmitsAggregateFrames() throws {
        let src = MemSrc(id: "sftp://a:22", remote: true)
        let dst = MemSrc(id: "local-t", remote: false)
        for n in ["a.bin", "b.bin"] {
            let p = "/src/\(n)"
            src.table[p] = src.item(p, size: 14)
            src.data[p] = Data(repeating: 7, count: 14)
        }
        src.dirItems = [src.table["/src/a.bin"]!, src.table["/src/b.bin"]!]
        let left = FilePane(id: .left, source: src, startPath: TCPath("/src"))
        let right = FilePane(id: .right, source: dst, startPath: TCPath("/dst"))
        left.load(); right.load()
        left.selectAll()          // 两文件都进操作目标（否则只传焦点项）

        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        var infos: [TransferEngine.TransferProgressInfo] = []
        te.run(true, left, right, cancel: CancelFlag()) { infos.append($0) }

        let overall = infos.filter { $0.overallBytesDone != nil && $0.overallBytesTotal != nil }
        XCTAssertFalse(overall.isEmpty, "修复前恒空 = 用户报障的帧管线缺席")
        XCTAssertTrue(overall.allSatisfy { $0.overallBytesTotal == 28 },
                      "total 恒 = 预扫描和 28")
        let dones = overall.map { $0.overallBytesDone! }
        XCTAssertEqual(dones, dones.sorted(), "聚合 done 单调")
        XCTAssertEqual(dones.last, 28, "末个聚合帧 done==total（finish 收口）")
        // 与单文件帧共存：pump 字节帧仍在场（overall nil = 面板回退分支素材）。
        XCTAssertTrue(infos.contains { $0.kind == .byte && $0.overallBytesDone == nil },
                      "单文件字节帧不得被聚合通道吃掉")
        // 文件完成帧携最新 overall（必达、不受节流 → 完成瞬间全进度即时）。
        XCTAssertTrue(infos.contains { $0.kind == .file && $0.overallBytesDone != nil },
                      "文件级帧应借用 throttle.overall")
    }

    /// 节流闸（独立时钟）：冻结时钟 → 聚合只过哨兵首帧；文件完成重置字节闸时
    /// **不**重置聚合闸（overall 借用已由 fileLevel 帧兜底即时性）。
    func testAggregateThrottleGate() throws {
        let src = MemSrc(id: "sftp://a:22", remote: true)
        let dst = MemSrc(id: "local-t", remote: false)
        let p = "/src/big.bin"
        src.table[p] = src.item(p, size: 28)
        src.data[p] = Data(repeating: 7, count: 28)      // 4 块 × 7B
        src.dirItems = [src.table[p]!]
        let left = FilePane(id: .left, source: src, startPath: TCPath("/src"))
        let right = FilePane(id: .right, source: dst, startPath: TCPath("/dst"))
        left.load(); right.load()

        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        te.progressClock = { 5 }                          // 冻结
        var infos: [TransferEngine.TransferProgressInfo] = []
        te.run(true, left, right, cancel: CancelFlag()) { infos.append($0) }

        let agg = infos.filter { $0.kind == .aggregate }
        XCTAssertEqual(agg.count, 1, "冻结时钟下聚合帧只剩哨兵首帧（节流生效），实得 \(agg.count)")
        // 时钟冻结但文件计数不冻结 → done==total 收口帧必达（收口不受节流 = finish 直发）。
        XCTAssertTrue(infos.contains { $0.overallBytesDone == 28 },
                      "收口/文件借用帧必须把账本推到底")
    }

    /// onProgress=nil（工具栏旧调用方）→ aggregate 不装（引擎连预扫描都不做）。
    func testNoProgressCallbackSkipsPlan() throws {
        let src = MemSrc(id: "sftp://a:22", remote: true)
        let dst = MemSrc(id: "local-t", remote: false)
        let p = "/src/a.bin"
        src.table[p] = src.item(p, size: 11)
        src.data[p] = Data("hello world".utf8)
        src.dirItems = [src.table[p]!]
        let left = FilePane(id: .left, source: src, startPath: TCPath("/src"))
        let right = FilePane(id: .right, source: dst, startPath: TCPath("/dst"))
        left.load(); right.load()
        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        te.run(true, left, right)                         // 无 onProgress
        XCTAssertEqual(dst.data["/dst/a.bin"], Data("hello world".utf8), "传输照常")
    }

    // MARK: - 锁 9：面板 overall 优先 / 回退 / 速度不重置

    private func info(name: String = "", fileDone: Int = 1, fileTotal: Int = 1,
                      bytesDone: Int64? = nil, bytesTotal: Int64? = nil,
                      route: CopyRoute? = nil,
                      overallDone: Int64? = nil, overallTotal: Int64? = nil)
        -> TransferEngine.TransferProgressInfo {
        TransferEngine.TransferProgressInfo(name: name, fileDone: fileDone, fileTotal: fileTotal,
                                            bytesDone: bytesDone, bytesTotal: bytesTotal,
                                            route: route,
                                            overallBytesDone: overallDone,
                                            overallBytesTotal: overallTotal)
    }

    /// overall 存在 → 条/明细用聚合值；后续单文件字节帧（done 回跳）**不得**
    /// 碰条与速度（闩锁）——用户报障「文件切换条回退」的鉴别锁。
    func testPanelPrefersOverallAndIgnoresPerFileFrames() throws {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 2, cancel: CancelFlag())
        let p = wc.probe

        wc.apply(info(fileDone: 0, fileTotal: 2, route: .relayed(.channelGone), overallDone: 150, overallTotal: 400))
        XCTAssertEqual(p.bar.doubleValue, 37.5, accuracy: 0.01, "条 = 聚合 150/400")
        XCTAssertTrue(p.detailLabel.stringValue.contains("400"), "明细含聚合总量")

        // 单文件帧（第二文件开始：done=50/100 → 若污染 = 条回 50%）。
        wc.apply(info(name: "f2", fileDone: 1, fileTotal: 2, bytesDone: 50, bytesTotal: 100))
        XCTAssertEqual(p.bar.doubleValue, 37.5, accuracy: 0.01, "单文件帧不得回拖聚合条（闩锁）")
        XCTAssertEqual(p.fileName.stringValue, "f2", "当前文件名仍随单文件帧更新")

        wc.apply(info(fileDone: 1, fileTotal: 2, route: .relayed(.channelGone), overallDone: 300, overallTotal: 400))
        XCTAssertEqual(p.bar.doubleValue, 75, accuracy: 0.01, "聚合推进照常反映")
    }

    /// overall=nil → 现状单文件分支回归（条 = bytesDone/bytesTotal）。
    func testPanelWithoutOverallKeepsLegacyBar() throws {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        let p = wc.probe
        wc.apply(info(name: "x.bin", fileDone: 0, fileTotal: 1, bytesDone: 30, bytesTotal: 100))
        XCTAssertEqual(p.bar.doubleValue, 30, accuracy: 0.01)
    }

    /// 速度跨文件不重置：overall 样本单调（300→350，dt≥0.5s）→ 速度非空且明细含速度。
    func testPanelSpeedUsesOverallSamplesAcrossFiles() throws {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 2, cancel: CancelFlag())
        let p = wc.probe
        wc.apply(info(fileDone: 1, fileTotal: 2, overallDone: 300, overallTotal: 400))
        // 第二文件继续（done 不回 0，聚合坐标）；速度窗需 ≥0.5s 跨度——
        // 两次 apply 真实间隔不足时 TransferSpeed 宁缺毋假（返回 nil）→ sleep 保证窗口。
        Thread.sleep(forTimeInterval: 0.55)
        wc.apply(info(fileDone: 1, fileTotal: 2, overallDone: 350, overallTotal: 400))
        // L10n.current=.en → transSpeed 模板 "{0}/s"。样本喂聚合 done（300→350 单调，
        // 非单文件 done）→ 跨文件速度非空（用户报障「文件切换速度回 0」正面解）。
        // 去闪改造后速度段 = 右 label（speedLabel），字节/总量段留在 detailLabel。
        XCTAssertTrue(wc.probe.speedLabel.stringValue.contains("/s"),
                      "右段应含速度，实得 \(wc.probe.speedLabel.stringValue)")
        XCTAssertTrue(wc.probe.detailLabel.stringValue.contains("400"), "明细含聚合总量分母")
    }
}
