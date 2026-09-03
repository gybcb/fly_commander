import XCTest
@testable import TCCore

/// Plan B Task 2/4：`CommandRouter.warnFormatter` 注入 —— TCCore 无 L10n，
/// 警告成品串必须由装配处注入的闭包组装；未注入时回落内部英文语义串。
///
/// 本类走纯 TCCore（router+engine+注入闭包），不依赖 AppKit/L10n，故住 TCCoreTests
/// （C3 卫生修正：此前误置于 FlyCommanderTests + `@testable import FlyCommander`）。
/// 状态栏成品串 statusText 的测试仍留 FlyCommanderTests（依赖 MainViewController.statusText）。
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
