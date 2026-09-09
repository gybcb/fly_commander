import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// T3 进度面板 SPM 构造断言：控件树（进度条 style/取消按钮/约束旗标）、
/// 纯格式化函数、headless 状态迁移（apply/finish/取消收口）。
/// 真窗上屏行为由 TransferProgressUITests（XCUITest）覆盖。
final class TransferProgressPanelTests: XCTestCase {
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

    private func info(name: String = "", fileDone: Int = 1, fileTotal: Int = 1,
                      bytesDone: Int64? = nil, bytesTotal: Int64? = nil,
                      route: CopyRoute? = nil) -> TransferEngine.TransferProgressInfo {
        TransferEngine.TransferProgressInfo(name: name, fileDone: fileDone, fileTotal: fileTotal,
                                            bytesDone: bytesDone, bytesTotal: bytesTotal, route: route)
    }

    // MARK: - 控件树构造

    /// 进度条必须是 .bar + 0~100 量程；取消按钮必须挂 target/action。
    /// 变异证伪：把 style 改 .spinning / minValue-maxValue 改乱 / 去掉 action 赋值，本测必红。
    func testProgressBarAndCancelButtonConstructed() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        let p = wc.probe
        XCTAssertEqual(p.bar.style, .bar, "进度条应为条形")
        XCTAssertEqual(p.bar.minValue, 0)
        XCTAssertEqual(p.bar.maxValue, 100)
        XCTAssertEqual(p.cancel.target as? TransferProgressWindowController, wc)
        XCTAssertNotNil(p.cancel.action, "取消按钮必须挂 action")
    }

    /// 缩减 SDK 坑守卫：内容视图树里所有受约束子视图必须
    /// translatesAutoresizingMaskIntoConstraints == false，否则窗口塌 ~12pt。
    /// 变异证伪：删任一 = false 赋值 → 对应子视图出现在违规列表。
    func testAllSubviewsDisableTranslatingMask() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        guard let content = wc.window?.contentView else { return XCTFail("contentView 缺失") }
        var violators: [String] = []
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if sub.translatesAutoresizingMaskIntoConstraints {
                    violators.append(String(describing: type(of: sub)))
                }
                walk(sub)
            }
        }
        walk(content)
        XCTAssertTrue(violators.isEmpty, "以下子视图漏设 translatesAutoresizingMaskIntoConstraints=false: \(violators)")
    }

    // MARK: - 纯格式化

    func testByteString() {
        XCTAssertEqual(TransferProgressWindowController.byteString(0),
                       ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
        // 负值钳到 0（剩余量估算瞬时为负时不显示 "−1 KB"）。
        XCTAssertEqual(TransferProgressWindowController.byteString(-5),
                       TransferProgressWindowController.byteString(0))
    }

    /// 时长格式 m:ss、2h 封顶、非法输入静默空串。
    /// 变异证伪：改 7200 阈值为 3600 → "75:00" 断言挂；去掉 NaN 守卫 → NaN 断言挂。
    func testDurationString() {
        let f = TransferProgressWindowController.durationString
        XCTAssertEqual(f(0), "0:00")
        XCTAssertEqual(f(83), "1:23")
        XCTAssertEqual(f(3599.4), "59:59")
        XCTAssertEqual(f(7199.6), "2h+", "四舍五入触顶也应封 2h+")
        XCTAssertEqual(f(7200), "2h+")
        XCTAssertEqual(f(86400), "2h+")
        XCTAssertEqual(f(-1), "")
        XCTAssertEqual(f(.nan), "")
        XCTAssertEqual(f(.infinity), "")
    }

    /// 全路由中文案非空且区分（服务器端 vs 四种回退原因各不同）。
    /// 变异证伪：任一 case 落到相同 L10nKey 或漏 case（编译挂）→ 相等断言挂。
    func testRouteTextDistinctPerCase() {
        let texts = [CopyRoute.serverSide,
                     .relayed(.execRejected), .relayed(.cpMissing),
                     .relayed(.unsupportedFlags), .relayed(.channelGone)].map {
            TransferProgressWindowController.routeText($0)
        }
        for t in texts { XCTAssertFalse(t.isEmpty) }
        XCTAssertEqual(Set(texts).count, 5, "五种路由文案应两两不同")
    }

    // MARK: - headless 状态迁移

    /// 字节帧 → determinate + 百分比 + 明细含字节数；文件帧（bytes=nil）→ 回落扫动态。
    /// 变异证伪：apply 里删 else 分支的 isIndeterminate 翻转 → 文件帧后条不回扫。
    func testApplySwitchesBarModeAndFillsDetail() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 2, cancel: CancelFlag())
        let p = wc.probe
        XCTAssertTrue(p.bar.isIndeterminate, "起始应扫动态")

        wc.apply(info(name: "big.bin", fileDone: 0, fileTotal: 2, bytesDone: 50, bytesTotal: 100))
        XCTAssertFalse(p.bar.isIndeterminate, "字节帧后应 determinate")
        XCTAssertEqual(p.bar.doubleValue, 50, accuracy: 0.001)
        XCTAssertTrue(p.detailLabel.stringValue.contains("50"), "明细应含已传字节")

        wc.apply(info(name: "", fileDone: 1, fileTotal: 2))
        XCTAssertTrue(p.bar.isIndeterminate, "文件帧（大小未知）应回扫动态")
    }

    /// 字节帧 name="" 沿用上一文件名（TransferEngine 字节帧不带名字）。
    /// 变异证伪：删 `if !info.name.isEmpty` 守卫 → 空串覆盖文件名，断言挂。
    func testByteFrameKeepsLastFileName() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.apply(info(name: "a.bin", fileDone: 0, fileTotal: 1, bytesDone: 1, bytesTotal: 10))
        wc.apply(info(name: "", fileDone: 0, fileTotal: 1, bytesDone: 2, bytesTotal: 10))
        XCTAssertEqual(wc.lastFileName, "a.bin")
        XCTAssertEqual(wc.probe.title.stringValue, L10n.t(.opCopying, "1") + " · 0/1")
    }

    /// 移动传输标题动词 = opMoving（presentTransfer 传入的 isCopy 必须贯穿 apply）。
    /// 变异证伪：apply 里把 .opCopying/.opMoving 二选一硬编码 → 另一动词断言挂。
    func testApplyTitleVerbFollowsIsCopy() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: false, fileTotal: 3, cancel: CancelFlag())
        wc.apply(info(fileDone: 1, fileTotal: 3))
        XCTAssertTrue(wc.probe.title.stringValue.hasPrefix(L10n.t(.opMoving, "3")),
                      "移动传输标题应以「Moving 3 item(s)」开头")
        wc.resetForTransferForTest(isCopy: true, fileTotal: 3, cancel: CancelFlag())
        wc.apply(info(fileDone: 1, fileTotal: 3))
        XCTAssertTrue(wc.probe.title.stringValue.hasPrefix(L10n.t(.opCopying, "3")))
    }

    /// done：条到 100%、按钮禁用、后续帧全吞（ended 幂等）；failed 同理吞帧。
    /// 变异证伪：finish 忘置 ended → done 后新帧改回 doubleValue，断言挂。
    func testFinishDoneLocksPanelAndSwallowsLaterFrames() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.finish(state: .done(label: .opCopying, args: ["1"], warningLines: []))
        let p = wc.probe
        XCTAssertEqual(p.bar.doubleValue, 100)
        XCTAssertEqual(p.title.stringValue, L10n.t(.transDone))
        XCTAssertFalse(p.cancel.isEnabled)
        wc.apply(info(name: "ghost", fileDone: 1, fileTotal: 1, bytesDone: 1, bytesTotal: 1))
        XCTAssertEqual(p.bar.doubleValue, 100, "done 后帧必须全吞")
    }

    func testFinishFailedKeepsPanelContentAndDisablesCancel() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.apply(info(name: "x.bin", fileDone: 0, fileTotal: 1, bytesDone: 30, bytesTotal: 100))
        wc.finish(state: .failed(.unknown("boom")))
        let p = wc.probe
        XCTAssertFalse(p.cancel.isEnabled)
        XCTAssertEqual(p.title.stringValue, L10n.t(.opCopying, "1") + " · 0/1",
                       "失败应驻留现场文案（错误文案归状态栏）")
    }

    /// 取消收口：finishCancelled 在 !ended 时关窗；已 done（ended）时幂等不误关。
    /// 变异证伪：删 finishCancelled 的 guard !ended → done 自动关窗竞态里二次触发路径改变可测。
    func testFinishCancelledClosesOnlyWhenNotEnded() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.finishCancelled()
        XCTAssertFalse(wc.window?.isVisible ?? true, "未终态时取消收口应立即关面板")

        // 再来一轮：done 后 finishCancelled 不得报错/不得改标题（幂等吞掉）。
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: CancelFlag())
        wc.finish(state: .done(label: .opCopying, args: ["1"], warningLines: []))
        wc.finishCancelled()
        XCTAssertEqual(wc.probe.title.stringValue, L10n.t(.transDone), "done 后取消收口应被 ended 吞掉")
    }

    /// 点取消：置旗（引擎在边界看到）+ 按钮禁用（原地等终态，不提前关窗）。
    /// 变异证伪：cancelPressed 忘 cancel?.cancel() → isCancelled 断言挂。
    func testCancelPressSetsFlagAndDisablesButton() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        let flag = CancelFlag()
        wc.resetForTransferForTest(isCopy: true, fileTotal: 1, cancel: flag)
        wc.clickCancelButtonForTest()
        XCTAssertTrue(flag.isCancelled)
        XCTAssertFalse(wc.probe.cancel.isEnabled)
    }

    // MARK: - 语言重刷守卫（PreviewWindowController 同型）

    /// 未创建时重刷绝不凭空建窗（否则 app 启动即多一个隐形面板单例）。
    /// 变异证伪：refreshLocalizedTextIfCreated 改成 `shared.refresh…` → 建窗，断言挂。
    func testRefreshDoesNotCreateWindowWhenNeverPresented() {
        XCTAssertFalse(TransferProgressWindowController.hasCreatedWindowForTest)
        L10n.current = .zh
        TransferProgressWindowController.refreshLocalizedTextIfCreated()
        XCTAssertFalse(TransferProgressWindowController.hasCreatedWindowForTest)
    }

    /// 已创建时重刷：窗口标题 + 取消按钮文案切语言并切回。
    func testRefreshRepaintsTitleAndCancelButton() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        L10n.current = .zh
        TransferProgressWindowController.refreshLocalizedTextIfCreated()
        XCTAssertEqual(wc.window?.title, L10n.t(.transferring))
        XCTAssertEqual(wc.probe.cancel.title, L10n.t(.transCancel))
        L10n.current = .en
        TransferProgressWindowController.refreshLocalizedTextIfCreated()
        XCTAssertEqual(wc.window?.title, L10n.t(.transferring))
        XCTAssertNotEqual(wc.probe.cancel.title, "取消", "旧中文串不应残留")
    }
}
