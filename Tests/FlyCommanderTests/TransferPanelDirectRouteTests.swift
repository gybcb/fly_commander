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
}
