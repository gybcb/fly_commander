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

    func testDoneWithWarningsEnglish() {
        XCTAssertEqual(
            MainViewController.statusText(for: .done(label: .opCopying, args: ["3"],
                                                     warningLines: ["w1", "w2"])),
            "Copying 3 item(s) complete ⚠ w1；w2")
    }
    func testDoneWithWarningsChinese() {
        L10n.current = .zh
        // zh 模板含前导全角空格（照现码 "　⚠ "）
        XCTAssertEqual(
            MainViewController.statusText(for: .done(label: .opCopying, args: ["3"],
                                                     warningLines: ["w1；w2"])),
            "复制 3 个文件 完成　⚠ w1；w2")
    }

    // MARK: - failed（TCError → 边界翻译，前缀走 statusErrorPrefix）

    func testFailedEnglish() {
        XCTAssertEqual(MainViewController.statusText(for: .failed(.busy("/x"))),
                       "Error: Busy: /x")
        XCTAssertEqual(MainViewController.statusText(for: .failed(.unknown("no file: /src/a.txt"))),
                       "Error: Error: no file: /src/a.txt")
    }
    func testFailedChinese() {
        L10n.current = .zh
        XCTAssertEqual(MainViewController.statusText(for: .failed(.busy("/x"))),
                       "错误：忙碌/被占用：/x")
    }

    func testIdleClears() {
        XCTAssertNil(MainViewController.statusText(for: .idle), "idle → nil（调用方清空状态栏）")
    }
}

/// Plan B Task 2：`CommandRouter.warnFormatter` 注入 —— TCCore 无 L10n，
/// 警告成品串必须由装配处注入的闭包组装；未注入时回落内部英文语义串。
final class CommandRouterWarnFormatterTests: XCTestCase {
    /// 最小内存源：跨源 move（sourceID 不同）→ 引擎传完删源；removeError 制造"删源失败"警告。
    private final class StubSource: FileSource {
        let sourceID: String
        var isRemote: Bool
        var supportsTransfer = true
        var data: [String: Data] = [:]
        var dirItems: [FileItem] = []
        var removeError: Error?

        init(id: String, remote: Bool) { sourceID = id; isRemote = remote }

        private func item(_ path: String) -> FileItem {
            FileItem(id: path, path: TCPath(path), name: (path as NSString).lastPathComponent,
                     isDirectory: false, size: Int64(data[path]?.count ?? 0),
                     modificationDate: .distantPast, isHidden: false,
                     isReadOnly: false, isExecutable: false)
        }
        func listDirectory(_ path: TCPath) throws -> [FileItem] { dirItems }
        func isDirectory(_ path: TCPath) -> Bool { false }
        func stat(_ path: TCPath) throws -> FileItem? { data[path.pathString].map { _ in item(path.pathString) } }
        func copyItem(from: TCPath, to: TCPath) throws { data[to.pathString] = data[from.pathString] }
        func moveItem(from: TCPath, to: TCPath) throws { data[to.pathString] = data.removeValue(forKey: from.pathString) }
        func renameItem(at: TCPath, to: TCPath) throws { data[to.pathString] = data.removeValue(forKey: at.pathString) }
        func makeDirectory(at: TCPath) throws {}
        func removeItem(at: TCPath) throws {
            if let e = removeError { throw e }
            data[at.pathString] = nil
        }
        func openReader(_ path: TCPath) throws -> ReadHandle {
            let payload = data[path.pathString] ?? Data()
            var sent = false
            return { _ in if sent { return nil }; sent = true; return payload }
        }
        func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {
            var buf = Data()
            while true { let c = try write(); if c.isEmpty { break }; buf.append(c) }
            data[path.pathString] = buf
        }
    }

    private func makeRouter() -> (Workspace, CommandRouter) {
        let src = StubSource(id: "stub-src", remote: true)
        src.data["/s/a.txt"] = Data("hello".utf8)
        src.dirItems = [FileItem(id: "/s/a.txt", path: TCPath("/s/a.txt"), name: "a.txt",
                                isDirectory: false, size: 5, modificationDate: .distantPast,
                                isHidden: false, isReadOnly: false, isExecutable: false)]
        src.removeError = TCError.busy("locked")
        let dst = StubSource(id: "stub-dst", remote: false)
        let left = FilePane(id: .left, source: src, startPath: TCPath("/s"))
        let right = FilePane(id: .right, source: dst, startPath: TCPath("/d"))
        left.load()
        right.load()
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        left.toggleMark()
        return (ws, router)
    }

    func testInjectedFormatterProducesLocalizedWarningLine() throws {
        let (ws, router) = makeRouter()
        router.warnFormatter = { name, err in "L10N[\(name)|\(err.message)]" }
        var last: OperationState?
        ws.onOperationState = { last = $0 }
        router.execute(.move)
        guard case .done(let label, let args, let warns)? = last else {
            return XCTFail("move 应完成并上报 .done，得到 \(String(describing: last))")
        }
        XCTAssertEqual(label, .opMoving)
        XCTAssertEqual(args, ["1"])
        XCTAssertEqual(warns, ["L10N[a.txt|Busy: locked]"], "注入闭包的产物原样进 .done：\(warns)")
    }

    /// 未注入（纯内核测试环境）→ 兜底内部英文串，不产中文。
    func testNilFormatterFallsBackToInternalEnglish() throws {
        let (ws, router) = makeRouter()
        var last: OperationState?
        ws.onOperationState = { last = $0 }
        router.execute(.move)
        guard case .done(_, _, let warns)? = last else {
            return XCTFail("move 应完成并上报 .done，得到 \(String(describing: last))")
        }
        XCTAssertEqual(warns, ["a.txt (Busy: locked)"], "兜底串：\(warns)")
    }
}
