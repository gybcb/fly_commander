import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// Task 4 桥接锁：直传字节帧从接缝抵达面板的两处数学——
/// ① TransferEngine.byteFrame 把 total==0（目录无预扫描、总量未知）桥成 bytesTotal=nil
///    → 面板走不定量扫动；② 面板 done>total 的累计帧（直传跨条目基线瞬时可越界）
///    百分比钳 100、剩余时间钳 ≥0。
/// 真 SFTP 路由镜像锁在 DirectConnectionProbeTests（需要真连接）。
final class TransferPanelDirectRouteTests: XCTestCase {
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

    // MARK: - byteFrame 桥接（total==0 → nil）

    /// 接缝对目录条目可发 total=0 的不定量帧（Task 1 askDirect 原样透传）。
    /// TransferEngine 必须桥成 bytesTotal=nil——面板 `total > 0` 判定消费的是 nil，
    /// 0 会穿进「有总量」分支渲染出 0/0。
    /// 变异证伪：byteFrame 里把 `total > 0 ? total : nil` 改成 `total` → nil 断言挂。
    func testByteFrameMapsZeroTotalToNil() {
        let f = TransferEngine.byteFrame(done: 500, total: 0, fileDone: 1, fileTotal: 2)
        XCTAssertEqual(f.bytesDone, 500)
        XCTAssertNil(f.bytesTotal, "total==0 必须桥成 nil（不定量）")
        XCTAssertEqual(f.fileDone, 1)
        XCTAssertEqual(f.fileTotal, 2)
        XCTAssertTrue(f.name.isEmpty, "字节帧不带名字（沿用上一帧）")
        XCTAssertNil(f.route, "字节帧不带 route（文件级帧携带）")
    }

    func testByteFramePassesPositiveTotalThrough() {
        let f = TransferEngine.byteFrame(done: 30, total: 100, fileDone: 0, fileTotal: 1)
        XCTAssertEqual(f.bytesTotal, 100)
    }

    /// 端到端语义：bytesTotal=nil 帧进面板 → 扫动态（不定量），不是 0/0 determinate。
    /// 变异证伪：面板 `total > 0` 放宽成 `bytesTotal != nil` → 0 总量条停扫不动。
    func testNilBytesTotalFrameRendersIndeterminate() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        // 先来一帧真总量 → 条进 determinate。
        wc.apply(TransferEngine.byteFrame(done: 40, total: 100, fileDone: 0, fileTotal: 1))
        XCTAssertFalse(wc.probe.bar.isIndeterminate)
        // 目录条目（总量未知）帧 → 必须回扫动态。
        wc.apply(TransferEngine.byteFrame(done: 500, total: 0, fileDone: 0, fileTotal: 1))
        XCTAssertTrue(wc.probe.bar.isIndeterminate, "total=0 桥 nil 后面板应不定量")
    }

    // MARK: - 面板钳制（Task 1 评审遗留 carry）

    /// 直传跨条目累计基线可让 done 瞬时 > total（askDirect 基线 + 接缝当前文件
    /// 自报 total 的错位窗口）。面板：百分比钳 100、剩余时间钳 ≥0（负剩余会把
    /// durationString 的负值守卫洗成空串——钳 0 后显示 0:00，可断言）。
    /// 变异证伪：删 remaining 的 max(0,…) → 负值进 durationString 返回 "" →
    /// 明细不含 "0:00" 断言挂。（百分比钳由 AppKit 也钳，单独断言无鉴别力，
    /// 剩余时间断言是本锁的鉴别项。）
    func testOvershootFrameClampsPercentAndRemaining() throws {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        // 速度估算需真实时钟窗口 ≥0.5s：两帧间隔 0.6s。
        wc.apply(TransferEngine.byteFrame(done: 40, total: 100, fileDone: 0, fileTotal: 1))
        Thread.sleep(forTimeInterval: 0.6)
        wc.apply(TransferEngine.byteFrame(done: 150, total: 100, fileDone: 0, fileTotal: 1))
        XCTAssertLessThanOrEqual(wc.probe.bar.doubleValue, 100)
        XCTAssertEqual(wc.probe.bar.doubleValue, 100, accuracy: 0.001,
                       "越界帧应钳到 100 而非回绕")
        XCTAssertTrue(wc.probe.detailLabel.stringValue.contains("0:00"),
                      "剩余钳 ≥0 → 显示 0:00；实得: \(wc.probe.detailLabel.stringValue)")
    }

    // MARK: - 接缝启用判定 + 参数装配（peer 方向直锁）

    private func sftpSource(host: String, port: UInt16, key: Bool = true) -> SFTPSource {
        SFTPSource(config: SFTPConnectionConfig(
            host: host, port: port, username: "u\(port)",
            auth: key ? .keyFile(path: "/nonexistent") : .password("p")))
    }

    private func fileItem(name: String, dir: Bool, size: Int64) -> FileItem {
        FileItem(id: name, path: TCPath("sftp://a:22/src/\(name)"), name: name,
                 isDirectory: dir, size: size, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    /// 判定表：双 SFTP 异机 + 源端 keyFile 才挂接缝；同源/密码认证/任一端本地 → nil。
    /// 变异证伪：directSeamSources 里删 supportsDirectCross 条件 → 密码认证断言挂；
    /// 删 sourceID 不等条件 → 同源断言挂。
    func testSeamGateTable() {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 2222)
        XCTAssertNotNil(TransferEngine.directSeamSources(src: a, dst: b))
        XCTAssertNil(TransferEngine.directSeamSources(src: a, dst: a), "同源不得挂接缝")
        let pw = sftpSource(host: "beta.example", port: 2222, key: false)
        XCTAssertNil(TransferEngine.directSeamSources(src: pw, dst: b), "源端密码认证无信任先天")
        let local = LocalFileSource()
        XCTAssertNil(TransferEngine.directSeamSources(src: local, dst: b), "源端本地")
        XCTAssertNil(TransferEngine.directSeamSources(src: a, dst: local), "目标端本地")
    }

    /// 方向直锁：peer 必须是**目标**服务器（rsync 在源机上执行、推给 peer）。
    /// e2e 夹具两端同为 127.0.0.1 看不出反向，故在此锁。
    /// 变异证伪：directSeamArgs 里 `sdst.peer` 改 `ssrc.peer` → host/user 断言挂。
    func testSeamArgsPeerIsDestination() {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 2222)
        let item = fileItem(name: "f.bin", dir: false, size: 7)
        let args = TransferEngine.directSeamArgs(ssrc: a, sdst: b, item: item,
                                                 destDir: TCPath("sftp://beta.example:2222/dst/f.bin"))
        XCTAssertEqual(args.peer.host, "beta.example", "peer 必须是目标机")
        XCTAssertEqual(args.peer.port, 2222)
        XCTAssertEqual(args.peer.username, "u2222")
    }

    /// dstPath = destDir 原样（接缝合同已给全路径，再拼名 = 吞名 bug）；
    /// totalHint 目录 0 / 文件 size。
    /// 变异证伪：dstPath 改成 destDir + item.name → dstPath 断言挂；
    /// totalHint 恒 item.size → 目录断言挂（0≠size）。
    func testSeamArgsPathsAndTotals() {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 22)
        let destFull = TCPath("sftp://beta.example/dst/f.bin")
        let f = TransferEngine.directSeamArgs(ssrc: a, sdst: b, item: fileItem(name: "f.bin", dir: false, size: 7),
                                              destDir: destFull)
        XCTAssertEqual(f.item.dstPath, "/dst/f.bin", "destDir 已含名，不得再拼")
        XCTAssertEqual(f.item.remotePath, "/src/f.bin")
        XCTAssertEqual(f.totalHint, 7)
        let d = TransferEngine.directSeamArgs(ssrc: a, sdst: b, item: fileItem(name: "d", dir: true, size: 4096),
                                              destDir: TCPath("sftp://beta.example/dst/d"))
        XCTAssertEqual(d.totalHint, 0, "目录无预扫描 = 总量未知")
        XCTAssertTrue(d.item.isDirectory)
    }

    /// 重叠传输守卫（评审 Important-2）：engine 是共享实例，上一 run 留下的接缝
    /// 必须被**不过 gate** 的 run 显式清掉——否则引擎拿 run1 的 ssrc/sdst 推 run2 的
    /// 条目（错服务器静默成功/硬失败）。锁法：共享 engine 上预挂计数哨兵接缝 →
    /// 跑一次两端本地的 run（gate 必不过）→ 断言哨兵零调用 + 接缝已 nil + 传输照常完成。
    /// 变异证伪：run() 的 else 分支 `engine.directCrossTransfer = nil` 删除 →
    /// 哨兵仍被 pump 前的 askDirect 触达（cross 判定走 pump 但 seam 非 nil 即被问）
    /// → 计数与 nil 断言双挂。
    func testGateMissRunClearsStaleSeamOnSharedEngine() throws {
        let op = OperationEngine()
        let te = TransferEngine(engine: op)
        te.runInBackground = { $0() }
        te.onMain = { $0() }

        // 哨兵：模拟上一（直传）run 遗留在共享引擎上的闭包。
        let hits = DirectSentinelBox()
        op.directCrossTransfer = { _, _, _ in
            hits.bump()
            return .unavailable("stale")
        }

        // 两端皆内存源（非 SFTP → gate 必不过）；跨 id → 引擎走 pump 路会问接缝。
        let src = DirectMemSource(id: "mem-src")
        let dst = DirectMemSource(id: "mem-dst")
        src.addFile("/src/a.txt", Data("hello".utf8))
        let srcPane = FilePane(id: .left, source: src, startPath: TCPath("/src"))
        srcPane.load()
        XCTAssertTrue(srcPane.revealItem(id: srcPane.itemByID.first { $0.value.name == "a.txt" }?.key ?? ""))
        let dstPane = FilePane(id: .right, source: dst, startPath: TCPath("/dst"))
        dstPane.load()

        te.run(true, srcPane, dstPane, cancel: CancelFlag(), onProgress: nil)

        XCTAssertEqual(hits.count, 0, "不过 gate 的 run 绝不得触达遗留接缝")
        XCTAssertNil(op.directCrossTransfer, "run 后共享引擎接缝必须已清")
        XCTAssertEqual(dst.data["/dst/a.txt"], Data("hello".utf8), "回退 pump 照常完成")
    }
}

/// 哨兵计数盒。
private final class DirectSentinelBox {
    private let lock = NSLock()
    var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

/// 最小内存源（够 pump 路跑通即可；形状抄 TransferEngineTests 的 MemSource 核心）。
private final class DirectMemSource: FileSource {
    let sourceID: String
    var table: [String: FileItem] = [:]
    var data: [String: Data] = [:]
    var dirItems: [FileItem] = []

    init(id: String) { sourceID = id }

    func addFile(_ path: String, _ payload: Data) {
        let item = FileItem(id: path, path: TCPath(path),
                            name: (path as NSString).lastPathComponent,
                            isDirectory: false, size: Int64(payload.count),
                            modificationDate: .distantPast, isHidden: false,
                            isReadOnly: false, isExecutable: false)
        table[path] = item
        data[path] = payload
        dirItems.append(item)
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirItems }
    func isDirectory(_ path: TCPath) -> Bool { false }
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
    }
}
