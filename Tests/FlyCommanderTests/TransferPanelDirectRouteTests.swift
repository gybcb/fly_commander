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
        XCTAssertNil(f.route, "默认无 route（引擎侧显式传帧路由）")
    }

    func testByteFramePassesPositiveTotalThrough() {
        let f = TransferEngine.byteFrame(done: 30, total: 100, fileDone: 0, fileTotal: 1)
        XCTAssertEqual(f.bytesTotal, 100)
    }

    /// 字节帧携带路由（用户可见性修复）：路由行此前只在**条目完成帧**出现 =
    /// 单条目传输全程无点、多条目只有完成瞬间一闪。byteFrame 加 route 参数，
    /// run() 的字节帧逐帧读当前路由（直传提前镜像/镜像回退都即时可见）。
    /// 变异证伪：byteFrame 忽略 route 参数恒 nil → 断言挂。
    func testByteFrameCarriesRoute() {
        let f = TransferEngine.byteFrame(done: 30, total: 100, fileDone: 0, fileTotal: 1,
                                         route: .directCrossHost)
        XCTAssertEqual(f.route, .directCrossHost)
    }

    // MARK: - 帧路由计划（色点语义只覆盖跨双服务器）

    /// 判定表：跨双 SFTP（sourceID 不等）才给路由（读目标连接的当前值）；
    /// 任一端本地 / 同一服务器 → nil。本地↔远程的「中转」无判断价值（必然中转），
    /// 且目标连接初值 .channelGone 会把「命令通道异常」这句谎话打上线——本函数把它挡住。
    /// 变异证伪：frameRoute 删本地端守卫 → 本地两条断言挂（SFTPSource 未连接读 nil
    /// 会假绿，故守卫必须显式在，不能靠 Optional chaining 兜）。
    func testFrameRoutePlan() {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 2222)
        let local = LocalFileSource()
        XCTAssertNil(TransferEngine.frameRoute(src: local, dst: b), "上传（源本地）不给点")
        XCTAssertNil(TransferEngine.frameRoute(src: a, dst: local), "下载（目标本地）不给点")
        // 同一服务器：透传（cp 路的 .serverSide 绿点是既有可见行为，本函数不得砍）。
        XCTAssertNil(TransferEngine.frameRoute(src: a, dst: a), "未连接透传 nil（连接后有 cp 真值）")
        // 跨双 SFTP：透传目标连接当前值（未连接 = nil 是合法初值，连接后见 e2e 锁）。
        XCTAssertNil(TransferEngine.frameRoute(src: a, dst: b), "未连接时透传 nil")
    }

    /// 无接缝跨服务器的种路由（诚实黄开局）：双 SFTP 异机但接缝不过 gate
    /// （= 源端密码认证，先天无 A→B 信任可测）→ `.relayed(.needsAuth)`。
    /// 变异证伪：noSeamSeedRoute 改成恒 nil → 首断言挂；同/本地端不守卫 → 其余挂。
    func testNoSeamSeedRouteTable() {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 2222)
        let pw = sftpSource(host: "gamma.example", port: 22, key: false)
        let local = LocalFileSource()
        XCTAssertNotNil(TransferEngine.noSeamSeedRoute(src: pw, dst: b))
        XCTAssertEqual(TransferEngine.noSeamSeedRoute(src: pw, dst: b), .relayed(.needsAuth))
        XCTAssertNil(TransferEngine.noSeamSeedRoute(src: a, dst: b), "过 gate 的路由由接缝镜像写")
        XCTAssertNil(TransferEngine.noSeamSeedRoute(src: a, dst: a), "同源不种")
        XCTAssertNil(TransferEngine.noSeamSeedRoute(src: local, dst: b), "本地端不种")
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

    /// 面板钳制（belt-and-braces，终审 B2 后仍在）：帧改为逐条目合同后 done>total 的
    /// **稳态**已不可能（分母与 done 同源），剩余风险 = 解析器对 openrsync 反推总量
    /// 的整型误差可让 done 瞬时超 total 几个字节。面板：百分比钳 100、剩余时间钳 ≥0
    /// （负剩余会把 durationString 的负值守卫洗成空串——钳 0 后显示 0:00，可断言）。
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

    // MARK: - B4 串行门（真安全机制：并发 run 不存在）

    /// 装配一对内存窗格（跨 id → 引擎走 pump 路）。reveal=false → 无标记 =
    /// operationTargets 空（空选早退路）。
    private func memPanes(payload: Data = Data("hello".utf8), reveal: Bool = true)
        -> (te: TransferEngine, src: DirectMemSource, dst: DirectMemSource,
            srcPane: FilePane, dstPane: FilePane) {
        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        let src = DirectMemSource(id: "mem-src"), dst = DirectMemSource(id: "mem-dst")
        src.addFile("/src/a.txt", payload)
        let srcPane = FilePane(id: .left, source: src, startPath: TCPath("/src")); srcPane.load()
        if reveal {
            _ = srcPane.revealItem(id: srcPane.itemByID.first { $0.value.name == "a.txt" }?.key ?? "")
        }
        let dstPane = FilePane(id: .right, source: dst, startPath: TCPath("/dst")); dstPane.load()
        return (te, src, dst, srcPane, dstPane)
    }

    /// 串行门主锁：**后台块延迟**（注入的 runInBackground 扣住不执行 = 在飞态）。
    /// 此刻第二个 run 必须被整个拒收 —— 断言 run2 的 state 回调零次触发
    /// （run 不碰引擎 = 接缝装配/performCopy 都没发生 = 错服务器写入不可能），
    /// 然后放行 run1：门释放 + 数据正确落目标。
    /// 变异证伪：run() 头部 `guard claimRunning()` 删除 → run2 也装配并跑完 →
    /// 「run2 不提交块 / 拒收 run 零回调 / 门仍占用」三断言全红。
    func testConcurrentRunIsRefusedWhileInFlight() throws {
        let a = memPanes()
        var deferred: [() -> Void] = []
        a.te.runInBackground = { deferred.append($0) }
        var stateCalls = 0
        a.te.state = { _ in stateCalls += 1 }
        var finished = 0
        a.te.onFinished = { _, _ in finished += 1 }

        a.te.run(true, a.srcPane, a.dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(deferred.count, 1, "run1 应把传输块交延迟器")
        XCTAssertTrue(a.te.isTransferRunning, "run1 交块后仍在飞")

        let before = stateCalls
        a.te.run(true, a.srcPane, a.dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(deferred.count, 1, "run2 不得提交第二个传输块")
        XCTAssertEqual(stateCalls, before, "被拒 run 零回调 = 根本没碰引擎")
        XCTAssertEqual(finished, 0, "被拒 run 不触发收尾（面板生命周期归 run1）")
        XCTAssertTrue(a.te.isTransferRunning, "run2 拒收不得把门放下")

        deferred[0]()                     // 放行 run1
        XCTAssertFalse(a.te.isTransferRunning, "完成 → 门必须释放")
        XCTAssertEqual(a.dst.data["/dst/a.txt"], Data("hello".utf8), "run1 数据照常正确")
        XCTAssertEqual(finished, 1)
    }

    /// 门不得卡死：抛错传输（注入 streamWrite 失败）也要放门。
    /// 变异证伪：releaseRunning 挪进 do 的成功路 → 抛错后 isTransferRunning 恒真 → 红。
    func testThrowingTransferReleasesRunningGate() throws {
        let a = memPanes()
        a.dst.failOnWrite = true   // 写侧 = 目标源（streamWrite 落在 dst）
        var failed = false
        a.te.state = { s in if case .failed = s { failed = true } }
        XCTAssertFalse(a.te.isTransferRunning)
        a.te.run(true, a.srcPane, a.dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertTrue(failed, "注入失败须上抛为 .failed（门不是吞错的借口）")
        XCTAssertFalse(a.te.isTransferRunning, "抛错路门必须释放（否则永久拒收后续传输）")
    }

    /// 空选择早退不得泄漏门（claim 之后的所有路成对；空选早退在 claim **之前**）。
    /// 形状：reveal=false 窗格（operationTargets 空）先跑一次 → 必须早退且不占门；
    /// 再 reveal 出条目跑真传输 → 必须照常落数据（证明上一步没把门卡住）。
    /// 变异证伪：claimRunning 挪到 targets.isEmpty 守卫之前 → 空选占门且无后台块放它 →
    /// 后续真传输被串行门拒收 → 数据断言红。
    func testEmptySelectionDoesNotWedgeGate() throws {
        let a = memPanes(reveal: false)   // 无标记 = 空选
        a.te.run(true, a.srcPane, a.dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertFalse(a.te.isTransferRunning, "空选早退不得占门")
        // 门没被空选占住 → reveal 后真传输照常跑通。
        _ = a.srcPane.revealItem(id: a.srcPane.itemByID.first { $0.value.name == "a.txt" }?.key ?? "")
        a.te.run(true, a.srcPane, a.dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(a.dst.data["/dst/a.txt"], Data("hello".utf8), "空选后真传输须照常完成")
    }

    // MARK: - N-a 条目边界清名字盒（混合批次 pump 帧不得携带上一条 rsync 名）

    /// 事故形态：条目 1 直传成功 → 名字盒=「big.bin」；条目 2 落 pump → pump 字节帧
    /// 读盒携带「big.bin」= 面板错名直到条目 2 完成帧。修法 = fileLevelFrame 进条目
    /// 边界第一件事清盒（生产 fileProgress 与锁**同一实现**，非抄写形状）。
    /// 变异证伪：fileLevelFrame 删 `nameBox.name = nil` → 第二条红（帧名非空）。
    func testFileLevelFrameClearsDirectNameBox() throws {
        let box = DirectNameBox()
        let targets = [fileItem(name: "big.bin", dir: true, size: 0),
                       fileItem(name: "small.txt", dir: false, size: 10)]
        box.name = "inner-inside-big.bin"          // 条目 1 直传期间 rsync 写进的名字
        let f1 = TransferEngine.fileLevelFrame(nameBox: box, targets: targets,
                                               done: 1, total: 2, route: .directCrossHost)
        XCTAssertEqual(f1.name, "big.bin", "完成帧名=条目名（rsync 内名不外泄）")
        XCTAssertNil(box.name, "进条目边界即清盒")
        // 条目 2 落 pump：字节帧名取自盒（directName）→ 清过 = 空串（面板沿用规则不受影响）。
        XCTAssertEqual(TransferEngine.directName(from: box), "")
    }

    // MARK: - N-b：不定量帧的无分母字节 + 速度（spec §3「已传字节…两路都有速度」）

    /// 直传目录条目（total=0→nil）旧 else 分支只扫条：无字节数、无速度、不喂样本
    /// = spec §3 承诺丢失。修法 = bytesDone 非 nil 时渲染「已传 · 速度」无分母式。
    /// 变异证伪（两处独立）：else 分支删 detailLabel 渲染 → 字节文本断言红；
    /// 删样本喂入 → "/s" 断言红。
    func testIndeterminateByteFrameShowsBytesAndSpeed() throws {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.apply(TransferEngine.byteFrame(done: 300_000, total: 0, fileDone: 0, fileTotal: 1))
        Thread.sleep(forTimeInterval: 0.6)
        wc.apply(TransferEngine.byteFrame(done: 900_000, total: 0, fileDone: 0, fileTotal: 1))
        XCTAssertTrue(wc.probe.bar.isIndeterminate, "无总量 → 条仍扫动（不假装 determinate）")
        let detail = wc.probe.detailLabel.stringValue
        XCTAssertTrue(detail.contains(TransferProgressWindowController.byteString(900_000)),
                      "无分母字节文本；实得: \(detail)")
        XCTAssertTrue(detail.contains("/s"), "速度须出现（喂样本 + L10n transSpeed）；实得: \(detail)")
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

    // MARK: - B4 per-run 令牌（两 run 都过 gate 的重叠）

    /// 事故形态（终审 B4）：run1/run2 都过 gate，run2 重赋接缝后 run1 引擎调到
    /// run2 的闭包 → run1 条目推往 run2 的两台服务器。**接缝工厂令牌锁**：
    /// 用假 rsync 造两个接缝闭包（token 1/2），run2 取号后调 run1 的闭包 →
    /// `.unavailable("stale-seam")` 且假 rsync **零触达**（stale 分支在触连接前返回
    /// = 「错服务器零写入」的直接证据）；自己的 token 则正常放行。
    /// 变异证伪：makeDirectSeam 删 token 守卫行 → stale 断言挂（跑进 rsync 计数 1）。
    func testStaleSeamClosureReturnsUnavailableWithoutTouchingRsync() throws {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 22)
        let box = DirectSeamTokenBox()
        let hits = DirectSentinelBox()
        let fakeRsync: (DirectRsync.ItemTarget, DirectRsync.Peer, Int64?,
                        ((Int64, Int64) -> Void)?, (String) -> Void, CancelFlag) throws -> DirectOutcome =
        { _, _, _, _, _, _ in hits.bump(); return .handled(bytesTransferred: 1) }

        let t1 = box.next()
        let seam1 = TransferEngine.makeDirectSeam(ssrc: a, sdst: b, cancel: CancelFlag(),
                                                  nameBox: DirectNameBox(), tokenBox: box,
                                                  myToken: t1, rsync: fakeRsync)
        XCTAssertEqual(try seam1(fileItem(name: "f", dir: false, size: 1),
                                 TCPath("/dst/f"), nil), .handled(bytesTransferred: 1),
                       "本 run 的接缝在 token 未过时须正常放行")
        _ = box.next()   // run2 取号 = 顶掉 run1
        XCTAssertEqual(try seam1(fileItem(name: "f", dir: false, size: 1),
                                 TCPath("/dst/f"), nil), .unavailable("stale-seam"),
                       "被顶掉的旧闭包必须立即 unavailable")
        XCTAssertEqual(hits.count, 1, "stale 分支不得触达 rsync（错服务器零写入）")
    }

    /// run() 头部确实取号（锁「run() 与工厂共用同一 token」这条接线；工厂逻辑锁归上一条）。
    /// 变异证伪：run() 删 `seamToken.next()` → 计数不动 → 红。
    func testRunAdvancesSeamToken() throws {
        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        let src = DirectMemSource(id: "mem-src"); let dst = DirectMemSource(id: "mem-dst")
        src.addFile("/src/a.txt", Data("x".utf8))
        let srcPane = FilePane(id: .left, source: src, startPath: TCPath("/src")); srcPane.load()
        _ = srcPane.revealItem(id: srcPane.itemByID.first { $0.value.name == "a.txt" }?.key ?? "")
        let dstPane = FilePane(id: .right, source: dst, startPath: TCPath("/dst")); dstPane.load()
        let tBefore = te.seamToken.current()
        te.run(true, srcPane, dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(te.seamToken.current(), tBefore + 1, "每次 run 令牌 +1")
    }

    // MARK: - B3 通道级异常分类（可测面）+ 接缝镜像 nil 兜底

    /// 两条通道异常路（openExec 抛 / nextEvent 抛）共享的分类函数（B3 可测面）。
    /// 只锁**可达且可构造**的分支：非 SSHClientError（POSIX/TCError 等）→ channelGone
    /// （保守：绝不当直传成功）。requestFailed→execRejected 的映射与 execute-cp 路共用
    /// 同一 relayReason(for:)（该分支构造需 Traversio 内部诊断，见
    /// ServerSideCopyCommandTests 同段说明），直传路可达性 = 同一函数 + 本 catch 调用点。
    /// 变异证伪：channelIssue 的 default 档改成 .execRejected → 本条红。
    func testChannelIssueClassification() throws {
        let o = SFTPConnection.channelIssue(POSIXError(.EIO))
        XCTAssertEqual(o.route, .relayed(.channelGone))
        XCTAssertEqual(o.outcome, .unavailable("channelGone"))
    }

    /// B5 装配锁：接缝把 rsync 回调的文件名写进名字盒（帧名链的接缝段）。
    /// 变异证伪：工厂里 onFile 回调改空闭包 → name 断言挂。
    func testSeamForwardsFileNameToNameBox() throws {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 22)
        let box = DirectSeamTokenBox()
        let nameBox = DirectNameBox()
        let seam = TransferEngine.makeDirectSeam(
            ssrc: a, sdst: b, cancel: CancelFlag(), nameBox: nameBox,
            tokenBox: box, myToken: box.next())
        { _, _, _, _, onFile, _ in onFile("report.pdf"); return .handled(bytesTransferred: 1) }
        _ = try seam(fileItem(name: "report.pdf", dir: false, size: 1), TCPath("/dst/f"), nil)
        XCTAssertEqual(nameBox.name, "report.pdf")
    }

    /// 首帧提前镜像绿点：假 rsync 发出**第一行真实进度**（该闸门在 SFTPClient
    /// 字节桥，能到这里 = 已连上 B 推字节）→ 接缝必须立刻把 `.directCrossHost`
    /// 镜像给目标源，且**先于**帧抵达调用方（否则面板首帧仍无点）。后续帧不得
    /// 重复提前镜像（收尾的真值镜像是另一次、应有的）。
    /// 变异证伪：makeDirectSeam 里删 bridged 包装（bp 原样透传）→ 首帧时刻
    /// mirrored 里还没有 directCrossHost → 红。
    func testFirstDirectFrameMirrorsGreenEarly() throws {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 22)   // 无连接：镜像=记录
        let box = DirectSeamTokenBox()
        var mirroredAtFirstFrame: [CopyRoute] = []
        let seam = TransferEngine.makeDirectSeam(
            ssrc: a, sdst: b, cancel: CancelFlag(), nameBox: DirectNameBox(),
            tokenBox: box, myToken: box.next())
        { _, _, _, bp, _, _ in
            // 真实顺序：rsync 解析出进度 → 桥发帧 → 收尾才 return。帧内必须已见绿。
            bp?(5, 10)
            mirroredAtFirstFrame = b.debugMirroredRoutes
            bp?(10, 10)
            return .handled(bytesTransferred: 10)
        }
        _ = try seam(fileItem(name: "f", dir: false, size: 10), TCPath("/dst/f")) { _, _ in }
        XCTAssertEqual(mirroredAtFirstFrame, [.directCrossHost],
                       "首帧抵达调用方时绿点已镜像（提前镜像先于帧），且只此一次")
        XCTAssertEqual(b.debugMirroredRoutes.count, 2,
                       "提前 1 次 + 收尾 1 次（收尾=src 无连接 nil 兜底黄=生产既有形状，本例不锁其值）")
    }

    /// 零字节回退路不得提前镜像：needsAuth 全程零帧（合同）→ 提前镜像的触发
    /// 条件（有帧）永不满足 → 目标源只看到收尾镜像（黄，src 无连接 → nil 兜底）。
    /// 变异证伪：把提前镜像挪到接缝入口（无条件写绿）→ 本锁的「无绿」断言挂。
    func testZeroFrameFallbackNeverMirrorsGreen() throws {
        let a = sftpSource(host: "alpha.example", port: 22)
        let b = sftpSource(host: "beta.example", port: 22)
        let box = DirectSeamTokenBox()
        let seam = TransferEngine.makeDirectSeam(
            ssrc: a, sdst: b, cancel: CancelFlag(), nameBox: DirectNameBox(),
            tokenBox: box, myToken: box.next())
        { _, _, _, _, _, _ in .unavailable("needsAuth") }   // 零帧
        _ = try seam(fileItem(name: "f", dir: false, size: 10), TCPath("/dst/f")) { _, _ in }
        XCTAssertFalse(b.debugMirroredRoutes.contains(.directCrossHost),
                       "零帧回退绝无绿点：\(b.debugMirroredRoutes)")
        XCTAssertEqual(b.debugMirroredRoutes.last, .relayed(.channelGone),
                       "只有收尾镜像（src 无连接 → nil 兜底黄）")
    }

    /// run() 接线锁：跨双「SFTP 形」源过不了真接缝（假源非 SFTPSource）时，
    /// 帧路由必须为 nil（本地/非 SFTP 端永不给点）。与 testSeamGateTable 互补：
    /// 那条锁判定，这条锁**帧管线**确实消费它。
    /// 变异证伪：run() 里把 route: frameRoute() 改成 route: .relayed(.channelGone)
    /// → 字节帧 route 断言挂。
    func testRunFramesHaveNoRouteForNonSFTPSources() throws {
        let a = memPanes()
        var frames: [TransferEngine.TransferProgressInfo] = []
        a.te.run(true, a.srcPane, a.dstPane, cancel: CancelFlag()) { frames.append($0) }
        XCTAssertFalse(frames.isEmpty, "传输须有帧")
        XCTAssertTrue(frames.allSatisfy { $0.route == nil },
                      "非 SFTP 端全程无路由：\(frames.compactMap(\.route))")
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
    /// 注入写失败（串行门「抛错路门必须释放」锁用）。
    var failOnWrite = false

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
        if failOnWrite { throw TCError.unknown("injected write failure") }
        var buf = Data()
        while true {
            let chunk = try write()
            if chunk.isEmpty { break }
            buf.append(chunk)
        }
        data[path.pathString] = buf
    }
}
