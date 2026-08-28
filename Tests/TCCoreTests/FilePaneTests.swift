import XCTest
import Foundation
@testable import TCCore

/// 最小 fake：listDirectory 返回预置条目（重复 id 容错用）。
private final class DupIDSource: FileSource {
    let items: [FileItem]
    init(items: [FileItem]) { self.items = items }
    var sourceID: String { "dup-test" }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { items }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

/// 远端 fake：stat 用信号量挂起（2s 超时兜底，旧同步实现不会挂死测试），
/// 验证 navigate 的远端 stat 不在主线程同步执行、在途导航可被失效。
private final class RemoteStubSource: FileSource {
    let gate = DispatchSemaphore(value: 0)
    var onStatEntered: (() -> Void)?
    var sourceID: String { "remote-stub" }
    var isRemote: Bool { true }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { [] }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? {
        onStatEntered?()
        _ = gate.wait(timeout: .now() + 2)   // 超时也返回目录项，旧实现下测试可失败而非挂死
        return FileItem(id: path.pathString, path: path, name: path.fileName,
                        isDirectory: true, size: 0, modificationDate: .distantPast,
                        isHidden: false, isReadOnly: false, isExecutable: true)
    }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

final class FilePaneTests: XCTestCase {
    private let source = LocalFileSource()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pane_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("dir1"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("zz"), withIntermediateDirectories: false)
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("file.txt").path, contents: Data([1,2,3]))
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoadPopulatesItemsAndSelection() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        var fired = 0
        pane.onReload = { _ in fired += 1 }
        pane.load()
        XCTAssertEqual(pane.itemCount, 3)                 // dir1, zz, file.txt（目录优先）
        XCTAssertEqual(pane.selection.focusIndex, 0)
        XCTAssertEqual(pane.page?.items.first?.name, "dir1")
        XCTAssertEqual(fired, 1)
    }

    func testNavigateAndParent() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 0, mode: .simple)              // focus dir1
        pane.enterFocusedDirectory()
        XCTAssertEqual(pane.path.url.lastPathComponent, "dir1")
        pane.gotoParent()
        XCTAssertEqual(pane.path.url.lastPathComponent, tmp.lastPathComponent)
        XCTAssertEqual(pane.selection.focusIndex, 0)      // navigation resets focus
    }

    func testReloadSameDirectoryPreservesFocus() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 2, mode: .simple)              // focus file.txt
        pane.load()                                       // same directory relist
        XCTAssertEqual(pane.selection.focusIndex, 2)
        XCTAssertTrue(pane.selection.focusID?.hasSuffix("file.txt") ?? false,
                      "focus: \(String(describing: pane.selection.focusID))")
    }

    func testRevealItem() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        let fileID = pane.page!.items.first { $0.name == "file.txt" }!.id
        XCTAssertTrue(pane.revealItem(id: fileID))
        XCTAssertEqual(pane.selection.focusIndex, 2)
        XCTAssertFalse(pane.revealItem(id: "/no/such/id"))
    }

    /// 进入一个**非首位**子目录后回退：焦点应落回该子目录本身，而非父目录的第一条。
    /// 默认序目录优先：dir1(0), zz(1), file.txt(2)——进入 zz(index 1) 再回退。
    func testGotoParentFocusesLeftChild() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 1, mode: .simple)              // 焦点到 zz（非首位）
        XCTAssertEqual(pane.page?.items[1].name, "zz")
        pane.enterFocusedDirectory()
        XCTAssertEqual(pane.path.url.lastPathComponent, "zz")
        pane.gotoParent()
        XCTAssertEqual(pane.path.url.lastPathComponent, tmp.lastPathComponent)
        XCTAssertEqual(pane.selection.focusIndex, 1, "回退后应聚焦刚离开的子目录，而非第一条")
        XCTAssertEqual(pane.focusedItem?.name, "zz")
    }

    func testOperationTargetsUsesSelection() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 2, mode: .simple)              // focus file.txt（dir1,zz,file.txt）
        XCTAssertEqual(pane.operationTargets.map { $0.name }, ["file.txt"])
        pane.toggleMark()                                  // mark file.txt
        pane.moveFocus(to: 0, mode: .additive)            // focus+mark dir1
        XCTAssertEqual(Set(pane.operationTargets.map { $0.name }), ["dir1", "file.txt"])
    }

    /// 远端列表由服务器返回，异常服务器可能给出重复 id——itemByID 不得 trap，
    /// 保留首条；operationTargets 等消费方照常工作。
    func testItemByIDToleratesDuplicateIDs() {
        func item(_ name: String) -> FileItem {
            FileItem(id: "/x/same", path: TCPath("/x/same"), name: name,
                     isDirectory: false, size: 1, modificationDate: .distantPast,
                     isHidden: false, isReadOnly: false, isExecutable: false)
        }
        let pane = FilePane(id: .left, source: DupIDSource(items: [item("a"), item("b")]),
                            startPath: TCPath("/x"))
        pane.load()   // 修复前：Dictionary(uniqueKeysWithValues:) 重复键 trap
        XCTAssertEqual(pane.itemCount, 2)
        XCTAssertEqual(pane.itemByID["/x/same"]?.name, "a", "重复 id 保留首条")
        // 同 id 两条目在 selection 里就是一个 id → operationTargets 恰一项
        XCTAssertEqual(pane.operationTargets.count, 1)
    }

    /// 远端 navigate：stat 不得在主线程同步执行（Enter 一次 = 一次网络 RTT 卡顿）。
    func testRemoteNavigateDefersPathChangeUntilStatCompletes() {
        let src = RemoteStubSource()
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/start"))
        var reloads = 0
        pane.onReload = { _ in reloads += 1 }
        let statEntered = expectation(description: "stat entered")
        src.onStatEntered = { statEntered.fulfill() }
        pane.navigate(to: TCPath("/target"))
        wait(for: [statEntered], timeout: 2)
        XCTAssertEqual(pane.path.pathString, "/start",
                       "stat 未完成前不得改 path（旧实现在主线程同步 stat 会改掉它）")
        src.gate.signal()
        let reloaded = expectation(description: "reload after navigate")
        pane.onReload = { _ in reloaded.fulfill() }
        wait(for: [reloaded], timeout: 2)
        XCTAssertEqual(pane.path.pathString, "/target")
    }

    /// stat 挂起时再次 navigate：第一次的在途 hop 必须被 token 失效（只应用最后一次）。
    func testSecondRemoteNavigateCancelsPendingFirst() {
        let src = RemoteStubSource()
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/start"))
        var reloads = 0
        pane.onReload = { _ in reloads += 1 }
        var statCount = 0
        let stat1 = expectation(description: "stat1")
        let stat2 = expectation(description: "stat2")
        src.onStatEntered = {
            statCount += 1
            (statCount == 1 ? stat1 : stat2).fulfill()
        }
        pane.navigate(to: TCPath("/first"))
        wait(for: [stat1], timeout: 2)
        src.gate.signal()                        // stat1 放行 → 其主线程 hop 入队（尚未执行）
        pane.navigate(to: TCPath("/second"))     // 应使第一次的 hop 失效
        src.gate.signal()                        // stat2 放行
        wait(for: [stat2], timeout: 2)
        // 双重 async 排干主队列（hop 与其触发的 reload 都落地后再断言）
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(pane.path.pathString, "/second")
        XCTAssertEqual(reloads, 1, "第一次导航的 hop 应被丢弃，只触发一次 reload：\(reloads)")
    }

    func testWorkspaceSwitchActive() {
        let a = FilePane(id: .left, source: source, startPath: TCPath("~"))
        let b = FilePane(id: .right, source: source, startPath: TCPath("~"))
        let ws = Workspace(left: a, right: b, active: .left)
        var fired = 0
        ws.onActiveChange = { _ in fired += 1 }
        XCTAssertEqual(ws.active, .left)
        ws.switchActive()
        XCTAssertEqual(ws.active, .right)
        XCTAssert(ws.activePane === b)
        XCTAssert(ws.inactivePane === a)
        XCTAssertEqual(fired, 1)
    }
}
