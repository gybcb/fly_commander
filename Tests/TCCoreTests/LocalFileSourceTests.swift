import XCTest
import Foundation
@testable import TCCore

final class LocalFileSourceTests: XCTestCase {
    private let src = LocalFileSource()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testListsDirectoriesFirstThenFilesSorted() throws {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("zeta_dir"), withIntermediateDirectories: false)
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("alpha").path, contents: Data([1]))
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("beta").path, contents: Data([1, 2]))
        let items = try src.listDirectory(TCPath(url: tmp))
        let names = items.map { $0.name }
        XCTAssertEqual(names.first, "zeta_dir")          // directory first
        XCTAssertEqual(Array(names.dropFirst()), ["alpha", "beta"]) // localized case-insensitive order
        XCTAssertEqual(items[0].isDirectory, true)
        XCTAssertEqual(items[0].size, 0)
    }

    func testFileSize() throws {
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("f").path, contents: Data(count: 42))
        let items = try src.listDirectory(TCPath(url: tmp))
        XCTAssertEqual(items[0].size, 42)
    }

    func testNonDirectoryThrows() {
        let file = tmp.appendingPathComponent("leaf")
        try? FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try src.listDirectory(TCPath(url: file)))
    }

    func testIsDirectory() {
        XCTAssertTrue(src.isDirectory(TCPath(url: tmp)))
    }
}
