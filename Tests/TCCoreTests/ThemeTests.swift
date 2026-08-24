import XCTest
@testable import TCCore

private func item(_ name: String, dir: Bool = false) -> FileItem {
    FileItem(id: "/\(name)", path: TCPath("/\(name)"), name: name, isDirectory: dir,
             size: 1, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

final class ThemeTests: XCTestCase {
    func testFileExtension() {
        XCTAssertEqual(fileExtension("a.txt"), "txt")
        XCTAssertEqual(fileExtension("a.TAR.gz"), "gz")     // 取最后一段，小写
        XCTAssertEqual(fileExtension("photo.JPG"), "jpg")
        XCTAssertEqual(fileExtension("readme"), nil)        // 无点
        XCTAssertEqual(fileExtension(".gitignore"), nil)    // 点在最前
        XCTAssertEqual(fileExtension("a."), nil)            // 尾点
    }

    func testMatchFileColorRule() {
        let rules = Theme.default.fileColorRules
        XCTAssertNotNil(matchFileColorRule(item("photo.png"), rules: rules))
        XCTAssertNotNil(matchFileColorRule(item("photo.PNG"), rules: rules))   // 大小写不敏感
        XCTAssertNotNil(matchFileColorRule(item("clip.webm"), rules: rules))   // webm → 视频
        XCTAssertNil(matchFileColorRule(item("sub.png", dir: true), rules: rules))  // 目录不上色
        XCTAssertNil(matchFileColorRule(item("readme"), rules: rules))         // 无扩展名
        XCTAssertNil(matchFileColorRule(item("data.xyz"), rules: rules))       // 未命中
    }

    func testFirstRuleWins() {
        let rules = [
            FileColorRule(extensions: ["png", "txt"], color: ThemeColor(red: 1, green: 0, blue: 0)),
            FileColorRule(extensions: ["txt"], color: ThemeColor(red: 0, green: 1, blue: 0)),
        ]
        XCTAssertEqual(matchFileColorRule(item("a.txt"), rules: rules)?.color,
                       ThemeColor(red: 1, green: 0, blue: 0))
    }

    func testCodableRoundTrip() throws {
        let t = Theme(appearance: .dark,
                      accent: ThemeColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9),
                      fileColorRules: [FileColorRule(extensions: ["a", "b"],
                                                     color: ThemeColor(red: 0, green: 1, blue: 1))])
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Theme.self, from: data)
        XCTAssertEqual(t, back)
    }

    func testDefaultThemeSane() {
        let d = Theme.default
        XCTAssertEqual(d.appearance, .system)
        XCTAssertFalse(d.fileColorRules.isEmpty, "出厂应带预置规则")
        for rule in d.fileColorRules {
            for ext in rule.extensions {
                XCTAssertEqual(ext, ext.lowercased(), "扩展名应小写：\(ext)")
                XCTAssertFalse(ext.contains("."), "扩展名不应含点：\(ext)")
                XCTAssertFalse(ext.isEmpty)
            }
        }
    }
}
