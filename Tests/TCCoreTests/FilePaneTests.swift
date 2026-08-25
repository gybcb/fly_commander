import XCTest
import Foundation
@testable import TCCore

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
