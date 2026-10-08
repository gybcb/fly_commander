import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 速度行去闪合同锁（用户报障「速度那一栏很闪，一跳一跳，字看不清楚」）。
///
/// 修法三件套（Bounded 设计获批 2026-10-08）：
/// ① detail 文本重写 ≥250ms 闸门 + 同内容去重（进度条不受闸，逐帧写）；
/// ② 速度 EMA 平滑（TransferSpeed.estimate 原始值不动，显示层阻尼）；
/// ③ detail 拆左右两 label：左=字节（钉 leading），右=速度·剩余（右对齐钉 trailing）。
/// 既有面板测试（TransferProgressPanelTests / TransferPanelDirectRouteTests /
/// TransferAggregatePanelTests）中「速度/剩余文本在 detailLabel」的断言随形状
/// 迁移到 speedLabel = 用户批准合同变更的适配，非回归。
final class TransferPanelSmoothTests: XCTestCase {
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

    private func byteInfo(done: Int64, total: Int64, fileDone: Int = 0, fileTotal: Int = 1)
        -> TransferEngine.TransferProgressInfo {
        TransferEngine.TransferProgressInfo(name: "", fileDone: fileDone, fileTotal: fileTotal,
                                            bytesDone: done, bytesTotal: total, route: nil)
    }

    // MARK: - 锁 E：真进度条不被文件完成帧打回扫动

    /// 用户报「假进度条」根因（代码核实）：文件完成帧（fileLevelFrame：bytesDone=nil）
    /// 落进 apply 的 else 分支 → **无条件** startAnimation → 每传完一个文件，
    /// determinate 条闪回扫动 = 假条。修法 = else 分支只在**从未进过定量**
    /// （lastBarTotal==nil）时才起扫动；一旦见过总量，文件完成帧不碰条。
    /// 变异证伪：删 lastBarTotal 守卫（恢复无条件 startAnimation）→ 第二断言红。
    func testFileCompletionFrameDoesNotRevertBarToIndeterminate() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 2, cancel: CancelFlag())
        // 定量字节帧 → 条进 determinate 40%。
        wc.apply(byteInfo(done: 40, total: 100, fileDone: 0, fileTotal: 2))
        XCTAssertFalse(wc.probe.bar.isIndeterminate, "字节帧后应 determinate")
        XCTAssertEqual(wc.probe.bar.doubleValue, 40, accuracy: 0.001)

        // 文件完成帧（bytesDone=nil、无 overall）→ 条**必须留在** determinate 40，不回扫。
        wc.apply(TransferEngine.TransferProgressInfo(name: "a.bin", fileDone: 1, fileTotal: 2,
                                                     bytesDone: nil, bytesTotal: nil, route: nil))
        XCTAssertFalse(wc.probe.bar.isIndeterminate,
                       "文件完成帧不得把真条打回扫动（假条根因）")
        XCTAssertEqual(wc.probe.bar.doubleValue, 40, accuracy: 0.001,
                       "完成帧不改条值（无新字节信息）")
    }

    // MARK: - 锁 F：多文件批次即使字节总量算不出，也能按文件数走真条

    /// 「可以明确计算的地方都用真条」：文件完成帧携 fileDone/fileTotal（多文件、
    /// total>1）→ 字节总量未知也按**文件完成度**走 determinate 真条（done/total×100），
    /// 不再扫动。单文件（fileTotal==1）无从按比例 → 维持扫动态（无意义 0/100 抖动）。
    /// 变异证伪：删按文件数分支（total==1 守卫反向 / 删 fileDone 条）→ 第二锁红。
    func testFileLevelFramesDriveRealBarByFileCount() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 4, cancel: CancelFlag())
        XCTAssertTrue(wc.probe.bar.isIndeterminate, "起始扫动态")

        // 无 overall、无字节，纯文件完成帧 2/4 → 真条 50%。
        wc.apply(TransferEngine.TransferProgressInfo(name: "b.bin", fileDone: 2, fileTotal: 4,
                                                     bytesDone: nil, bytesTotal: nil, route: nil))
        XCTAssertFalse(wc.probe.bar.isIndeterminate, "多文件完成帧应走真条")
        XCTAssertEqual(wc.probe.bar.doubleValue, 50, accuracy: 0.001,
                       "条 = fileDone/fileTotal = 2/4")

        wc.apply(TransferEngine.TransferProgressInfo(name: "d.bin", fileDone: 4, fileTotal: 4,
                                                     bytesDone: nil, bytesTotal: nil, route: nil))
        XCTAssertEqual(wc.probe.bar.doubleValue, 100, accuracy: 0.001, "末文件完成 → 100%")
    }

    /// 字节总量可算时**优先字节真条**（比文件数更细）：文件数条不得覆盖字节坐标。
    /// 变异证伪：把文件数分支放到字节分支之前 → 首帧条 = 0（fileDone/fileTotal）红。
    func testByteCoordinateWinsOverFileCount() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 4, cancel: CancelFlag())
        wc.testDetailClock = { 5 }
        // 字节 25/100 且 fileDone=1/4：字节坐标应胜出 = 25%（不是 fileDone/total=25… 需可区分值）。
        wc.apply(byteInfo(done: 60, total: 100, fileDone: 1, fileTotal: 4))
        XCTAssertEqual(wc.probe.bar.doubleValue, 60, accuracy: 0.001,
                       "有字节总量 → 用字节百分比，非文件数")
    }

    /// 单文件批次（fileTotal==1）无字节总量 → 维持扫动态（0/1 无比例意义，别假装真条）。
    /// 变异证伪：删 fileTotal>1 守卫 → isIndeterminate 变 false 红。
    func testSingleFileNoBytesStaysIndeterminate() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.apply(TransferEngine.TransferProgressInfo(name: "x.bin", fileDone: 1, fileTotal: 1,
                                                     bytesDone: nil, bytesTotal: nil, route: nil))
        XCTAssertTrue(wc.probe.bar.isIndeterminate, "单文件无字节 → 无意义比例，维持扫动")
    }

    // MARK: - 锁 A：文本重写 250ms 闸（进度条不闸）

    /// 冻结时钟连打 8 帧内容互异的字节帧 → 文本只重写 1 次（首帧），
    /// 但进度条 doubleValue 必须跟到最后一帧（逐帧写 = 进度感，不是闪）。
    /// 变异证伪：删 250ms 闸 → 计数 == 8 红。
    func testDetailTextRewriteThrottledButBarNotGated() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.testDetailClock = { 5 }                        // 冻结 → 首帧后闸恒关
        for i in 1...8 {
            wc.apply(byteInfo(done: Int64(i * 100), total: 1000))
        }
        XCTAssertEqual(wc.detailRewriteCount, 1,
                       "冻结时钟下文本只应重写首帧一次，实得 \(wc.detailRewriteCount)")
        XCTAssertEqual(wc.probe.bar.doubleValue, 80, accuracy: 0.001,
                       "条不受文本闸约束（逐帧推进）")
    }

    // MARK: - 锁 B：同内容去重

    /// 时钟推进但内容不变 → 不重写；内容变化 → 重写。
    /// 变异证伪：删同串去重 → 第一断言（count 恒 1）红。
    func testDetailRewriteSkippedWhenContentUnchanged() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        var t: TimeInterval = 5
        wc.testDetailClock = { t += 1; return t }         // 每次取时 +1s → 闸常开
        wc.apply(byteInfo(done: 500, total: 1000))
        wc.apply(byteInfo(done: 500, total: 1000))        // 同内容 → 去重
        wc.apply(byteInfo(done: 500, total: 1000))
        XCTAssertEqual(wc.detailRewriteCount, 1, "同内容重复帧不得重写")
        wc.apply(byteInfo(done: 600, total: 1000))        // 内容变 → 重写
        XCTAssertEqual(wc.detailRewriteCount, 2)
    }

    // MARK: - 锁 C：EMA 平滑纯函数

    /// 首值直填种子；新原始值按 α 阻尼靠拢；raw=nil（窗口不足）→ 保持上次值不清零。
    /// 变异证伪：α 改 1.0 → 175 断言红；删 raw-nil 保持分支 → 第三断言红。
    func testSpeedSmoothingIsDampedEMA() {
        XCTAssertEqual(TransferProgressWindowController.smooth(prev: nil, raw: 400)!,
                       400, "首值直填")
        XCTAssertEqual(TransferProgressWindowController.smooth(prev: 100, raw: 400)!,
                       175, accuracy: 0.001, "α=0.25 阻尼：100+0.25×300")
        XCTAssertEqual(TransferProgressWindowController.smooth(prev: 175, raw: nil),
                       175, "估算缺席保持上次值（断流不清 0）")
        // 阻尼性质：多帧逼近下 |out−prev| ≤ α|raw−prev|。
        var s = 100.0
        for _ in 0..<5 { s = TransferProgressWindowController.smooth(prev: s, raw: 500)! }
        XCTAssertLessThan(s, 500, "5 帧仍未跳到 raw（EMA 未收敛完 = 阻尼在工作）")
        XCTAssertGreaterThan(s, 100, "确实在向 raw 靠拢")
    }

    // MARK: - 锁 D：两 label 同行 + 右对齐锚

    /// 定量帧渲染后：speedLabel 与 detailLabel 垂直区间重合（同一行），
    /// speedLabel 右对齐（宽度波动被 trailing 锚吸收 = 数字不互推），
    /// 路由行仍在两 label 之下（既有布局锁的扩展）。
    /// 变异证伪：speedLabel 改左对齐钉 leading → alignment/几何断言红。
    func testSpeedLabelIsRightAlignedInDetailRow() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.apply(byteInfo(done: 500_000, total: 1_000_000))
        // 真时钟窗口喂速度：sleep 保证 estimate ≥0.5s。
        Thread.sleep(forTimeInterval: 0.6)
        wc.apply(byteInfo(done: 800_000, total: 1_000_000))
        guard let content = wc.window?.contentView else { return XCTFail("无 contentView") }
        content.layoutSubtreeIfNeeded()

        XCTAssertTrue(wc.probe.speedLabel.stringValue.contains("/s"),
                      "速度段应在右 label，实得 \(wc.probe.speedLabel.stringValue)")
        XCTAssertTrue(wc.probe.detailLabel.stringValue.contains(
                          TransferProgressWindowController.byteString(800_000)),
                      "字节段留在左 label")
        XCTAssertEqual(wc.probe.speedLabel.alignment, .right, "右对齐（trailing 锚吸宽）")

        let d = wc.probe.detailLabel.frame, s = wc.probe.speedLabel.frame
        let sameRow = d.minY < s.maxY && s.minY < d.maxY
        XCTAssertTrue(sameRow, "两 label 同行（区间垂直重合）d=\(d) s=\(s)")
        XCTAssertLessThanOrEqual(s.maxX, content.bounds.maxX, "右 label 不得越出内容区")
        // 路由行独立成行（非翻转坐标：之下 = maxY ≤ detail 行 minY）。
        wc.applyProbeRoute(.serverSide)
        content.layoutSubtreeIfNeeded()
        let route = wc.probe.routeLabel.frame
        XCTAssertFalse(wc.probe.routeLabel.isHidden, "route 帧必须已渲染")
        XCTAssertLessThanOrEqual(route.maxY, min(d.minY, s.minY) + 0.5,
                                 "路由行在 detail 行之下 route=\(route) d=\(d) s=\(s)")
    }

    // MARK: - 锁 G：超大总量下进度可读（真机日志实证 2026-10-08）

    /// 真机指纹：112.5GB 批次，聚合帧恒到、done 单调、条恒 determinate，
    /// 但 done/total 像素增量 <1px → 条视觉不动 + AppKit 亚像素插值 =
    /// 用户报「滚来滚去没显示进度」。修法 = 左段追加百分比数字。
    /// 变异证伪：删百分比段 → contains("0.1%") 红。
    func testPercentNumberShownForHugeTotal() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.testDetailClock = { 5 }
        // 112.5GB 总量里传 112.5MB = 0.1% ——条像素 ≈ 0（肉眼不可见），数字必须可见。
        wc.apply(TransferEngine.TransferProgressInfo(name: "", fileDone: 0, fileTotal: 1,
                                                     bytesDone: nil, bytesTotal: nil, route: nil,
                                                     overallBytesDone: 120_810_549,
                                                     overallBytesTotal: 120_810_549_170))
        XCTAssertTrue(wc.probe.detailLabel.stringValue.contains("0.1%"),
                      "左段须含百分比数字，实得 \(wc.probe.detailLabel.stringValue)")
    }

    /// 条像素量化闸：百分比变化 <0.25pt **不写条**（消亚像素闪动）；≥0.25pt 才写；
    /// 收口 100 必写（哪怕 Δ<0.25）；每次传输首写必出。
    /// 变异证伪：删量化闸（恒写）→ 第二断言红；删 100 特判 → 收口断言红。
    func testBarWritesQuantizedToPixelGranularity() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.testDetailClock = { 5 }
        let total: Int64 = 100_000
        func agg(_ done: Int64) -> TransferEngine.TransferProgressInfo {
            TransferEngine.TransferProgressInfo(name: "", fileDone: 0, fileTotal: 1,
                                                bytesDone: nil, bytesTotal: nil, route: nil,
                                                overallBytesDone: done, overallBytesTotal: total)
        }
        wc.apply(agg(100))          // 0.1% → 首写必出
        XCTAssertEqual(wc.probe.bar.doubleValue, 0.1, accuracy: 0.001)
        wc.apply(agg(110))          // Δ0.01 <0.25 → 不写（亚像素闪 = 根因）
        wc.apply(agg(120))
        XCTAssertEqual(wc.probe.bar.doubleValue, 0.1, accuracy: 0.001,
                       "亚像素变化不得写条（闪动根因）")
        wc.apply(agg(500))          // Δ0.4 ≥0.25 → 写
        XCTAssertEqual(wc.probe.bar.doubleValue, 0.5, accuracy: 0.001)
        // 收口必写：99.9→100（Δ0.1 <0.25）仍必须落 100。
        wc.apply(agg(99_900))
        XCTAssertEqual(wc.probe.bar.doubleValue, 99.9, accuracy: 0.01)
        wc.apply(agg(100_000))
        XCTAssertEqual(wc.probe.bar.doubleValue, 100, accuracy: 0.001, "收口 100 必写")
    }
}
