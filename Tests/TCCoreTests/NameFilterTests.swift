import XCTest
import Foundation
@testable import TCCore

/// NameFilter：默认大小写不敏感子串；含 `*`/`?` 时切换为通配符（全串锚定）。
final class NameFilterTests: XCTestCase {

    // MARK: - 空模式

    /// 空串 = 无筛选，恒真。
    /// 变异：把 `case .empty: return true` 改成 `return false` → 本用例红。
    func testEmptyMatchesEverything() {
        let f = NameFilter("")
        XCTAssertTrue(f.isEmpty)
        XCTAssertTrue(f.matches(""))
        XCTAssertTrue(f.matches("anything.txt"))
        XCTAssertTrue(f.matches("目录"))
    }

    // MARK: - 子串语义

    /// 子串大小写不敏感。
    /// 变异：把 `[.caseInsensitive]` 改成 `[]` → 本用例红（PDF 不命中）。
    func testSubstringIsCaseInsensitive() {
        let f = NameFilter("pdf")
        XCTAssertFalse(f.isEmpty)
        XCTAssertTrue(f.matches("a.PDF"))
        XCTAssertTrue(f.matches("REPORT.Pdf"))
    }

    /// 子串是**包含**而非全串相等（`pdf` 命中 `a.pdf`）。
    /// 变异：把 `range(of:options:)` 改成 `name == text` → 本用例红。
    func testSubstringIsNotFullString() {
        let f = NameFilter("pdf")
        XCTAssertTrue(f.matches("a.pdf"))
        XCTAssertTrue(f.matches("pdf"))
        XCTAssertTrue(f.matches("a.pdf.bak"), "包含即可，不看位置")
        XCTAssertFalse(f.matches("a.pd"), "不完整子串不命中")
    }

    /// 子串不走正则：正则元字符按字面（`a+b` 不命中 `aab`）。
    /// 变异：把子串实现换成 `NSRegularExpression` → `a+b` 命中 `aab`，本用例红。
    func testSubstringTreatsRegexMetacharsLiterally() {
        let f = NameFilter("a+b")
        XCTAssertTrue(f.matches("x a+b y"))
        XCTAssertFalse(f.matches("aab"))
        XCTAssertFalse(f.matches("ab"))
    }

    // MARK: - 通配符语义（含 `*` 或 `?` 即切换）

    /// `*.pdf` 走通配符且**全串锚定**：`a.pdf` 命中，`a.pdf.bak`/`a.pdfx` 不命中。
    /// 变异：把 `^…$` 锚定去掉 → `a.pdf.bak` 命中，本用例红。
    func testWildcardStarIsAnchored() {
        let f = NameFilter("*.pdf")
        XCTAssertTrue(f.matches("a.pdf"))
        XCTAssertTrue(f.matches("报告.pdf"))
        XCTAssertFalse(f.matches("a.pdf.bak"))
        XCTAssertFalse(f.matches("a.pdfx"))
    }

    /// `report?.txt`：`?` 恰一个字符，且 `.` 是字面量。
    /// 变异：把 `.` 的 `escapedPattern` 改成直接拼接 → `abc` 也命中，本用例红。
    func testWildcardQuestionAndLiteralDot() {
        let f = NameFilter("report?.txt")
        XCTAssertTrue(f.matches("report1.txt"))
        XCTAssertFalse(f.matches("report.txt"), "? 恰一个字符")
        XCTAssertFalse(f.matches("report12.txt"))
        XCTAssertFalse(f.matches("report1xtxt"), ". 是字面量")
    }

    /// 通配符同样大小写不敏感。
    /// 变异：把 `caseSensitive: false` 改成 `true` → 本用例红。
    func testWildcardIsCaseInsensitive() {
        XCTAssertTrue(NameFilter("*.PDF").matches("a.pdf"))
        XCTAssertTrue(NameFilter("A?C").matches("abc"))
    }

    /// 单个 `?` 即进入通配符模式（不是子串）。
    /// 变异：把 `contains("?")` 判断去掉 → 退化为子串，`d` 也命中，本用例红。
    func testSingleQuestionMarkSwitchesToWildcard() {
        let f = NameFilter("?")
        XCTAssertTrue(f.matches("d"))
        XCTAssertFalse(f.matches("dd"))
    }

    // MARK: - 不 trim（明确取舍）

    /// 空白按字面匹配：`a b` 只命中名字含空格的项，不命中 `ab`。
    /// 变异：在 init 里加 `text.trimmingCharacters(in: .whitespaces)` → `ab` 命中，本用例红。
    func testWhitespaceIsLiteralNotTrimmed() {
        let f = NameFilter("a b")
        XCTAssertTrue(f.matches("a b.txt"))
        XCTAssertFalse(f.matches("ab.txt"))
        XCTAssertFalse(NameFilter(" ").matches("ab"))
        XCTAssertTrue(NameFilter(" ").matches("a b"))
    }
}
