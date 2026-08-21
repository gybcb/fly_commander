import XCTest
import Foundation
@testable import TCCore

final class OperationEngineTests: XCTestCase {
    private let engine = OperationEngine()
    private var src: URL!
    private var dst: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("op_\(UUID().uuidString)")
        src = base.appendingPathComponent("src")
        dst = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
    }

    private func copyTargets(_ dir: URL) throws -> [FileItem] {
        try LocalFileSource().listDirectory(TCPath(url: dir))
    }

    func testCopyCreatesDestinations() throws {
        try engine.performCopy(try copyTargets(src), to: TCPath(url: dst))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("sub").path))
    }

    func testCopySkipAll() throws {
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try engine.performCopy(try copyTargets(src), to: TCPath(url: dst)) { _, _ in .skipAll }
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "old")
    }

    func testCopyOverwrite() throws {
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try engine.performCopy(try copyTargets(src), to: TCPath(url: dst)) { _, _ in .overwrite }
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
    }

    func testCopyCancelThrows() {
        try? "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try engine.performCopy(try! copyTargets(src), to: TCPath(url: dst)) { _, _ in .cancel })
    }

    func testMoveRemovesSource() throws {
        try engine.performMove(try copyTargets(src), to: TCPath(url: dst))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
    }

    func testRename() throws {
        let items = try copyTargets(src)
        let a = items.first { $0.name == "a.txt" }!
        try engine.performRename(a, to: "renamed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("renamed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }

    func testMakeDirectory() throws {
        let newDir = try engine.performMakeDirectory("newd", in: TCPath(url: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.url.path))
    }
}
