import XCTest
@testable import TCCore

/// 目录/批量拷贝的全进度（聚合字节通道）引擎合同锁。
///
/// 背景（用户报障）：拷目录时面板进度条/速度只反映**当前单文件**
/// （帧合同 bytesDone/bytesTotal = 条内值，终审 B2 裁定不得在帧里偷加基线）
/// → 整目录全进度不可见。
/// 设计（用户批准）：预扫描求整批总量（失败/超预算 = 总量未知 → **零聚合帧**，
/// 宁缺毋假）+ 新旁路参数 `aggregate:(整批累计, 总量)`。合同 = done 单调、
/// 末帧 done==total；条内帧 = 基线 + 观测值（min 钳总量）。跳过条目按计划量
/// 推进基线（账本为准）。既有单文件参数与语义一字不动。
final class TransferPlanProgressTests: XCTestCase {

    // MARK: - 假源（仿 OperationEngineRoutingTests 的记录型形状）

    private final class FakeSource: FileSource {
        let sourceID: String
        var isRemote = true
        var supportsTransfer = true
        var statTable: [String: FileItem] = [:]
        var listTable: [String: [FileItem]] = [:]
        var chunksByPath: [String: [Data]] = [:]
        var listThrowFor: String?            // 该路径 listDirectory 抛错（预扫描失败路）
        var listThrowRemaining = 0           // >0 = 前 N 次对 listThrowFor 的抛错（1 = 瞬时故障：扫描挂、传输路可列）
        var sameSourceFrames: [(Int64, Int64)] = []   // copyItem 重载回放的 cp 轮询帧
        private(set) var sameSourceOverloadPaths: [String] = []
        private(set) var streamWrites: [(path: String, data: Data)] = []

        init(id: String) { sourceID = id }
        func listDirectory(_ path: TCPath) throws -> [FileItem] {
            if path.pathString == listThrowFor, listThrowRemaining != 0 {
                if listThrowRemaining > 0 { listThrowRemaining -= 1 }
                throw TCError.unknown("list boom")
            }
            return listTable[path.pathString] ?? []
        }
        func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
        func stat(_ path: TCPath) throws -> FileItem? { statTable[path.pathString] }
        func copyItem(from: TCPath, to: TCPath) throws {}
        func copyItem(from: TCPath, to: TCPath,
                      byteProgress: ((Int64, Int64) -> Void)?) throws {
            sameSourceOverloadPaths.append(from.pathString)
            for (d, t) in sameSourceFrames { byteProgress?(d, t) }
        }
        func moveItem(from: TCPath, to: TCPath) throws {}
        func renameItem(at: TCPath, to: TCPath) throws {}
        func makeDirectory(at: TCPath) throws {}
        func removeItem(at: TCPath) throws {}
        func openReader(_ path: TCPath) throws -> ReadHandle {
            var i = 0
            let chunks = chunksByPath[path.pathString] ?? []
            return { _ in
                guard i < chunks.count else { return nil }
                let c = chunks[i]; i += 1
                return c
            }
        }
        func streamWrite(_ path: TCPath, totalBytes: Int64?,
                         write: @escaping () throws -> Data) throws {
            var data = Data()
            while true {
                let chunk = try write()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            streamWrites.append((path.pathString, data))
        }
    }

    private func fileItem(_ path: String, size: Int64) -> FileItem {
        let name = path.components(separatedBy: "/").last ?? path
        return FileItem(id: path, path: TCPath(path), name: name, isDirectory: false,
                        size: size, modificationDate: .distantPast, isHidden: false,
                        isReadOnly: false, isExecutable: false)
    }
    private func dirItem(_ path: String) -> FileItem {
        let name = path.components(separatedBy: "/").last ?? path
        return FileItem(id: path, path: TCPath(path), name: name, isDirectory: true,
                        size: 0, modificationDate: .distantPast, isHidden: false,
                        isReadOnly: false, isExecutable: false)
    }

    /// 跨源目录夹具：/src/tree = f1(100) f2(100) + sub/{f3(100) f4(100)} = 400。
    private func makeTree(src: FakeSource) throws -> [FileItem] {
        src.statTable["/src/tree/f1"] = fileItem("/src/tree/f1", size: 100)
        src.statTable["/src/tree/f2"] = fileItem("/src/tree/f2", size: 100)
        src.statTable["/src/tree/sub/f3"] = fileItem("/src/tree/sub/f3", size: 100)
        src.statTable["/src/tree/sub/f4"] = fileItem("/src/tree/sub/f4", size: 100)
        src.listTable["/src/tree"] = [
            fileItem("/src/tree/f1", size: 100), fileItem("/src/tree/f2", size: 100),
            dirItem("/src/tree/sub"),
        ]
        src.listTable["/src/tree/sub"] = [
            fileItem("/src/tree/sub/f3", size: 100), fileItem("/src/tree/sub/f4", size: 100),
        ]
        for p in ["/src/tree/f1", "/src/tree/f2", "/src/tree/sub/f3", "/src/tree/sub/f4"] {
            src.chunksByPath[p] = [Data(count: 100)]
        }
        return [dirItem("/src/tree")]
    }

    // MARK: - 预扫描 + 聚合帧合同

    /// 跨源两文件：聚合帧必须带基线（第二文件期间出现 done>100 的帧 = 全进度
    /// 而非单文件进度——用户报障的鉴别力锁），done 单调、封顶 total、末帧 done==total。
    func testCrossSourceTwoFilesAggregateCarriesBaselineAndEndsAtPlan() throws {
        let a = FakeSource(id: "a"), b = FakeSource(id: "b")
        a.statTable["/s/x.bin"] = fileItem("/s/x.bin", size: 100)
        a.statTable["/s/y.bin"] = fileItem("/s/y.bin", size: 100)
        a.chunksByPath["/s/x.bin"] = [Data(count: 50), Data(count: 50)]   // 双块 = 可分观测
        a.chunksByPath["/s/y.bin"] = [Data(count: 50), Data(count: 50)]
        let engine = OperationEngine()
        var frames: [(Int64, Int64)] = []
        try engine.performCopy([fileItem("/s/x.bin", size: 100), fileItem("/s/y.bin", size: 100)],
                               to: TCPath("/d"), srcSource: a, dstSource: b,
                               aggregate: { d, t in frames.append((d, t)) })
        XCTAssertFalse(frames.isEmpty, "aggregate 必须收到帧（修复前恒空 = 全进度缺席根因）")
        XCTAssertTrue(frames.allSatisfy { $0.1 == 200 }, "总量恒 = 预扫描和 200")
        let dones = frames.map { $0.0 }
        XCTAssertEqual(dones, dones.sorted(), "done 单调不减")
        XCTAssertLessThanOrEqual(dones.max() ?? 0, 200, "封顶 total")
        XCTAssertEqual(frames.last?.0, 200, "末帧 done==total")
        XCTAssertEqual(frames.last?.1, 200)
        XCTAssertGreaterThan(dones.max() ?? 0, 100,
            "第二文件期间必须有 done>100 的帧（基线缺失 = 只能显示单文件进度）")
        XCTAssertTrue(dones.contains { $0 > 100 && $0 < 200 },
            "必须有 (100,200) 开区间的**观测**帧（= 基线 100 + 条内部分观测 50/100）；"
            + "endEntry 的 200 不能顶替——变异证伪（intra 丢基线）落点：\(dones)")
    }

    /// 目录递归预扫描 = 整棵树字节和（嵌套子目录计入）。
    func testDirectoryPlanIsRecursiveTreeSum() throws {
        let a = FakeSource(id: "a"), b = FakeSource(id: "b")
        let items = try makeTree(src: a)
        let engine = OperationEngine()
        var frames: [(Int64, Int64)] = []
        try engine.performCopy(items, to: TCPath("/d"), srcSource: a, dstSource: b,
                               aggregate: { d, t in frames.append((d, t)) })
        XCTAssertTrue(frames.allSatisfy { $0.1 == 400 }, "目录 total = 树和 400，实得 \(frames.map { $0.1 })")
        XCTAssertEqual(frames.last?.0, 400, "末帧 done==total")
        XCTAssertEqual(frames.last?.1, 400)
    }

    /// 顶层条目被跳过（冲突 prompt=skip）→ 基线按计划量推进（否则进度条卡死）。
    func testSkippedEntryAdvancesBaselineByPlannedBytes() throws {
        let a = FakeSource(id: "a"), b = FakeSource(id: "b")
        a.statTable["/s/x.bin"] = fileItem("/s/x.bin", size: 100)
        a.chunksByPath["/s/x.bin"] = [Data(count: 100)]
        b.statTable["/d/y.bin"] = fileItem("/d/y.bin", size: 100)   // 目标挡路 → 冲突
        let engine = OperationEngine()
        var frames: [(Int64, Int64)] = []
        let prompt: ConflictPrompt = { _, dst in
            dst.pathString == "/d/y.bin" ? .skip : .overwrite
        }
        try engine.performCopy([fileItem("/s/x.bin", size: 100), fileItem("/s/y.bin", size: 100)],
                               to: TCPath("/d"), srcSource: a, dstSource: b,
                               prompt: prompt,
                               aggregate: { d, t in frames.append((d, t)) })
        XCTAssertTrue(b.streamWrites.allSatisfy { $0.path != "/d/y.bin" }, "skip 不该传 y")
        XCTAssertEqual(frames.last?.0, 200, "跳过的条目按计划量推进：末帧仍 done==total")
        XCTAssertEqual(frames.last?.1, 200)
    }

    /// 预扫描超预算（5001 条目 > 5000）→ 总量未知 → **零聚合帧**（宁缺毋假，
    /// 传输照常完成；面板维持旧观感 = 无全进度 ≠ 挡传输）。
    func testBudgetExceededSuppressesAllAggregateFrames() throws {
        let a = FakeSource(id: "a"), b = FakeSource(id: "b")
        let many = (0..<5001).map { fileItem("/s/big/f\($0)", size: 1) }
        a.listTable["/s/big"] = many
        for f in many { a.chunksByPath[f.path.pathString] = [Data(count: 1)] }
        let engine = OperationEngine()
        var frames: [(Int64, Int64)] = []
        try engine.performCopy([dirItem("/s/big")], to: TCPath("/d"), srcSource: a, dstSource: b,
                               aggregate: { d, t in frames.append((d, t)) })
        XCTAssertTrue(frames.isEmpty, "超预算 = 未知 → 一条聚合帧都不发（半账本 = 撒谎）")
        XCTAssertEqual(b.streamWrites.count, 5001, "预扫描失败不挡传输")
    }

    /// 预扫描 list 抛错 → 同样零聚合帧、传输照常（降级路两分支同合同）。
    func testPlanFailureSuppressesFramesButNotTransfer() throws {
        let a = FakeSource(id: "a"), b = FakeSource(id: "b")
        let items = try makeTree(src: a)
        a.listThrowFor = "/src/tree/sub"
        a.listThrowRemaining = 1        // 只对预扫描那次抛错；传输路 list 正常 → 传输照常
        var frames: [(Int64, Int64)] = []
        let engine = OperationEngine()
        try engine.performCopy(items, to: TCPath("/d"), srcSource: a, dstSource: b,
                               aggregate: { d, t in frames.append((d, t)) })
        XCTAssertTrue(frames.isEmpty, "扫描失败 → 未知 → 不发帧")
        XCTAssertFalse(b.streamWrites.isEmpty, "扫描失败不挡传输")
    }

    /// 同源 cp 黑盒路：实现方帧 = (条内 done, 条内 total)，引擎聚合通道折算为
    /// (基线 + done, 整批 total)——账本集中在聚合侧折算，不违 :334「帧里不偷加」。
    func testSameSourceCopyItemFramesShiftedByBaseline() throws {
        let s = FakeSource(id: "same")
        let engine = OperationEngine()
        s.sameSourceFrames = [(0, 100), (50, 100), (100, 100)]
        var frames: [(Int64, Int64)] = []
        try engine.performCopy([fileItem("/s/x.bin", size: 100), fileItem("/s/y.bin", size: 100)],
                               to: TCPath("/d"), srcSource: s, dstSource: s,
                               aggregate: { d, t in frames.append((d, t)) })
        XCTAssertEqual(s.sameSourceOverloadPaths, ["/s/x.bin", "/s/y.bin"])
        XCTAssertTrue(frames.allSatisfy { $0.1 == 200 })
        let dones = frames.map { $0.0 }
        XCTAssertEqual(dones, dones.sorted(), "单调")
        XCTAssertEqual(frames.last?.0, 200)
        XCTAssertEqual(frames.last?.1, 200)
        // 第二条目期间的观测帧必须落在 (100,200) 开区间（基线 100 + 条内观测）。
        XCTAssertTrue(dones.contains { $0 > 100 && $0 < 200 },
            "第二文件条内帧 = 基线 100 + 观测（变异证伪落点），实得 \(dones)")
    }

    /// aggregate=nil（既有全部调用方）→ 零聚合帧、单文件合同不回归。
    func testNilAggregateKeepsLegacyBehavior() throws {
        let a = FakeSource(id: "a"), b = FakeSource(id: "b")
        a.statTable["/s/x.bin"] = fileItem("/s/x.bin", size: 100)
        a.chunksByPath["/s/x.bin"] = [Data(count: 100)]
        var bytes: [(Int64, Int64)] = []
        let engine = OperationEngine()
        try engine.performCopy([fileItem("/s/x.bin", size: 100)], to: TCPath("/d"),
                               srcSource: a, dstSource: b,
                               byteProgress: { d, t in bytes.append((d, t)) })
        XCTAssertEqual(bytes.last?.0, 100, "单文件帧合同不变")
        XCTAssertEqual(bytes.last?.1, 100)
    }
}
