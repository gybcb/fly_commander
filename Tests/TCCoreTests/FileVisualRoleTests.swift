import XCTest
import Foundation
@testable import TCCore

func makeItem(name: String, isDir: Bool = false, hidden: Bool = false, readOnly: Bool = false) -> FileItem {
    FileItem(id: "/d/" + name, path: TCPath("/d/" + name), name: name, isDirectory: isDir,
             size: isDir ? 0 : 10, modificationDate: .distantPast,
             isHidden: hidden, isReadOnly: readOnly, isExecutable: false)
}

final class FileVisualRoleTests: XCTestCase {
    func testFocusWins() {
        XCTAssertEqual(visualRole(for: makeItem(name: "x", isDir: true), isMarked: true, isFocus: true), .focus)
    }
    func testMarkedBeatsDirectory() {
        XCTAssertEqual(visualRole(for: makeItem(name: "d", isDir: true), isMarked: true, isFocus: false), .marked)
    }
    func testHiddenBeatsDirectory() {
        XCTAssertEqual(visualRole(for: makeItem(name: ".d", isDir: true, hidden: true), isMarked: false, isFocus: false), .hidden)
    }
    func testReadOnly() {
        XCTAssertEqual(visualRole(for: makeItem(name: "r", readOnly: true), isMarked: false, isFocus: false), .readOnly)
    }
    func testDirectoryBoldRole() {
        XCTAssertEqual(visualRole(for: makeItem(name: "d", isDir: true), isMarked: false, isFocus: false), .directory)
    }
    func testNormal() {
        XCTAssertEqual(visualRole(for: makeItem(name: "f"), isMarked: false, isFocus: false), .normal)
    }
}
