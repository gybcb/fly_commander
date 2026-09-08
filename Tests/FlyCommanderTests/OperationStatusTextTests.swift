import XCTest
@testable import FlyCommander
import TCCore

/// Plan B Task 2：状态栏组装纯函数 `MainViewController.statusText(for:)`。
/// 内核/传输层只发 L10nKey + 结构化参数，中文/英文成品串**只在这里**组装，
/// 故状态标签天然随语言即时切换（每次操作回调现取，不缓存）。
final class OperationStatusTextTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    // MARK: - running

    func testRunningEnglish() {
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opCopying, args: ["3"], progress: 0.5)),
                       "Copying 3 item(s) 50%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opMoving, args: ["1"], progress: 0)),
                       "Moving 1 item(s) 0%")
        // rename/mkdir 的 running 复用 Plan A 现键，无插值参数
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .rename, args: [], progress: 0)),
                       "Rename 0%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .newDirectory, args: [], progress: 0)),
                       "New Directory 0%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opSearchRunning, args: [], progress: 0)),
                       "Searching 0%")
        // 删除 running（MainViewController 删除产点，此前无 SPM 覆盖，Minor5 补）
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opDeleteRunning, args: ["2"], progress: 0.5)),
                       "Deleting 2 item(s) 50%")
    }
    func testRunningChinese() {
        L10n.current = .zh
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opCopying, args: ["3"], progress: 0.5)),
                       "复制 3 个文件 50%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opMoving, args: ["1"], progress: 1)),
                       "移动 1 个文件 100%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .rename, args: [], progress: 0)),
                       "重命名 0%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .newDirectory, args: [], progress: 0)),
                       "新建目录 0%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opSearchRunning, args: [], progress: 0)),
                       "搜索 0%")
        XCTAssertEqual(MainViewController.statusText(for: .running(label: .opDeleteRunning, args: ["2"], progress: 0.5)),
                       "删除 2 个文件 50%")
    }

    // MARK: - done

    func testDoneEnglish() {
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opCopying, args: ["3"], warningLines: [])),
                       "Copying 3 item(s) complete")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opMoving, args: ["3"], warningLines: [])),
                       "Moving 3 item(s) complete")
        // 成品句键（已重命名/已新建目录/已删除 N 个/搜索完成）逐字显示，不再包"完成"
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opRenameDone, args: [], warningLines: [])),
                       "Renamed")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opMkdirDone, args: [], warningLines: [])),
                       "Directory created")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opDeleteDone, args: ["2"], warningLines: [])),
                       "Deleted 2 item(s)")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opSearchDone, args: ["7"], warningLines: [])),
                       "Search complete, 7 result(s)")
    }
    func testDoneChinese() {
        L10n.current = .zh
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opCopying, args: ["3"], warningLines: [])),
                       "复制 3 个文件 完成")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opRenameDone, args: [], warningLines: [])),
                       "已重命名")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opMkdirDone, args: [], warningLines: [])),
                       "已新建目录")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opDeleteDone, args: ["2"], warningLines: [])),
                       "已删除 2 个文件")
        XCTAssertEqual(MainViewController.statusText(for: .done(label: .opSearchDone, args: ["7"], warningLines: [])),
                       "搜索完成，7 个结果")
    }

    // MARK: - done + warnings（警告是**已本地化成品串**，这里只负责拼接与 ⚠ 前后缀）
    // join 分隔符本身也随语言（.statusWarnJoin：en "; " / zh "；"），防英文状态栏流中文标点。

    func testDoneWithWarningsEnglish() {
        XCTAssertEqual(
            MainViewController.statusText(for: .done(label: .opCopying, args: ["3"],
                                                     warningLines: ["w1", "w2"])),
            "Copying 3 item(s) complete ⚠ w1; w2")
    }
    func testDoneWithWarningsChinese() {
        L10n.current = .zh
        // zh 模板含前导全角空格（照现码 "　⚠ "）；分隔符走 zh 全角"；"。
        XCTAssertEqual(
            MainViewController.statusText(for: .done(label: .opCopying, args: ["3"],
                                                     warningLines: ["w1", "w2"])),
            "复制 3 个文件 完成　⚠ w1；w2")
    }

    // MARK: - failed（TCError → 边界翻译，前缀走 statusErrorPrefix）

    func testFailedEnglish() {
        XCTAssertEqual(MainViewController.statusText(for: .failed(.busy("/x"))),
                       "Error: Busy: /x")
        // R-C1 裁决：errUnknown 模板改裸 {0} 后双前缀消解——状态栏只有一层 "Error: "。
        XCTAssertEqual(MainViewController.statusText(for: .failed(.unknown("no file: /src/a.txt"))),
                       "Error: no file: /src/a.txt")
    }
    func testFailedChinese() {
        L10n.current = .zh
        XCTAssertEqual(MainViewController.statusText(for: .failed(.busy("/x"))),
                       "错误：忙碌/被占用：/x")
        // zh 同为单层前缀（哨兵：锁 R-C1 不回退到 "错误：错误："）。
        XCTAssertEqual(MainViewController.statusText(for: .failed(.unknown("disk full"))),
                       "错误：disk full")
    }

    func testIdleClears() {
        XCTAssertNil(MainViewController.statusText(for: .idle), "idle → nil（调用方清空状态栏）")
    }

    /// 结构守卫（C2）：套"X 完成"的标签键集合必须恰为两个进度标签（opCopying/opMoving），
    /// 且任何成品句（*Done）都不得误投进去——否则 statusText 会给成品句再套"完成"变成
    /// "已重命名 完成"这类畸形。改集合=改语义，须同步本测。
    func testAppendCompleteLabelsStructureGuard() {
        XCTAssertEqual(MainViewController.appendCompleteLabels, [.opCopying, .opMoving],
                       "套完成模板的集合应恰为两个进度标签")
        let doneKeys = L10nKey.allCases.filter {
            $0.rawValue.hasPrefix("op") && $0.rawValue.hasSuffix("Done")
        }
        XCTAssertFalse(doneKeys.isEmpty, "前置：应存在 op*Done 成品句键")
        for k in doneKeys {
            XCTAssertFalse(MainViewController.appendCompleteLabels.contains(k),
                           "成品句 \(k.rawValue) 不得进套完成模板集合")
        }
    }
}
