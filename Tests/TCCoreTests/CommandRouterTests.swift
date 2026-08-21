import XCTest
import Foundation
@testable import TCCore

final class CommandRouterTests: XCTestCase {
    private var leftDir: URL!
    private var rightDir: URL!
    private var workspace: Workspace!
    private var router: CommandRouter!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rtr_\(UUID().uuidString)")
        leftDir = base.appendingPathComponent("L")
        rightDir = base.appendingPathComponent("R")
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)
        try "a".write(to: leftDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "z".write(to: leftDir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: TCPath(url: leftDir))
        let right = FilePane(id: .right, source: source, startPath: TCPath(url: rightDir))
        workspace = Workspace(left: left, right: right, active: .left)
        router = CommandRouter(workspace: workspace, engine: OperationEngine())
        left.load()
        right.load()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: leftDir.deletingLastPathComponent())
    }

    func testDownMovesFocus() {
        router.execute(.down, moveMode: .simple)
        XCTAssertEqual(workspace.activePane.selection.focusIndex, 1)
    }

    func testCopyToInactivePane() {
        router.execute(.copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
    }

    func testMoveToInactivePane() {
        router.execute(.move)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("a.txt").path))
    }

    func testRenameViaMethod() {
        workspace.activePane.moveFocus(to: 0, mode: .simple)
        router.rename(to: "changed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("changed.txt").path))
    }

    func testMakeDirectoryViaMethod() {
        router.makeDirectory(named: "newdir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("newdir").path))
    }

    func testDeleteDelegatesToOnDelete() {
        var got: [FileItem] = []
        router.onDelete = { _, items in got = items }
        router.execute(.delete)
        XCTAssertEqual(got.map { $0.name }, ["a.txt"])
    }

    func testOperationStateEmittedOnCopy() {
        var last: OperationState?
        workspace.onOperationState = { last = $0 }
        router.execute(.copy)
        if case .done = last {
            // expected
        } else {
            XCTFail("expected .done, got \(String(describing: last))")
        }
    }
}
