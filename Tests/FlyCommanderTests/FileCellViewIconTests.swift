import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import FlyCommander
import TCCore

/// 远端图标类型推导（`FileCellView.iconType`）纯函数单测。
/// 远端无本地文件，按 目录/扩展名 推 UTType；本地图标行为不变（不在此测）。
final class FileCellViewIconTests: XCTestCase {
    private func item(_ name: String, dir: Bool = false) -> FileItem {
        FileItem(id: "sftp://h/\(name)", path: TCPath("sftp://h/\(name)"),
                 name: name, isDirectory: dir, size: 0, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: dir)
    }

    func testDirectoryMapsToFolder() {
        XCTAssertEqual(FileCellView.iconType(for: item("docs", dir: true)), .folder)
    }

    func testNoExtensionMapsToData() {
        XCTAssertEqual(FileCellView.iconType(for: item("Makefile")), .data)
    }

    func testKnownExtensionNotPlainData() {
        XCTAssertNotEqual(FileCellView.iconType(for: item("a.png")), .data, "png 应解析成图像类型")
        XCTAssertNotEqual(FileCellView.iconType(for: item("a.txt")), .data, "txt 应解析成文本类型")
    }
}
