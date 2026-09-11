import XCTest
@testable import TCCore

/// 版本比较纯函数回归锁。每条带变异证伪注释（改哪行 → 哪条红）。
final class VersionCompareTests: XCTestCase {

    func testNumericSegmentCompare() {
        XCTAssertTrue(VersionCompare.isUpdate("0.0.6", newerThan: "0.0.5"))
        XCTAssertTrue(VersionCompare.isUpdate("0.1.0", newerThan: "0.0.9"))
        XCTAssertTrue(VersionCompare.isUpdate("1.0.0", newerThan: "0.9.9"))
        XCTAssertFalse(VersionCompare.isUpdate("0.0.5", newerThan: "0.0.6"), "旧不比新新")
        // 变异证伪：把 compare 里 av>bv 与 av<bv 的返回序对调 → 首条红。
    }

    func testMultiDigitSegment() {
        // 段内是数值比较非字典序：10 > 2。
        XCTAssertTrue(VersionCompare.isUpdate("0.10.0", newerThan: "0.9.0"))
        XCTAssertFalse(VersionCompare.isUpdate("0.2.0", newerThan: "0.10.0"))
        // 变异证伪：segments 若用 String 字典序比较（不转 Int）→ 第二条假红/第一条假绿。
    }

    func testUnequalSegmentCountPadsZero() {
        XCTAssertEqual(VersionCompare.compare("0.1", "0.1.0"), .orderedSame, "缺失段补 0")
        XCTAssertTrue(VersionCompare.isUpdate("0.1.1", newerThan: "0.1"), "0.1 == 0.1.0 < 0.1.1")
        XCTAssertFalse(VersionCompare.isUpdate("0.1", newerThan: "0.1.0"), "补零后相等 → 不提示")
        // 变异证伪：删 segments 补齐（直接 zip 短侧）→ compare("0.1","0.1.0") 非 orderedSame 红。
    }

    func testNonNumericSegmentFallsBackZero() {
        // 畸形/带后缀段按 0，保守不误报升级（"beta"→0）。
        XCTAssertFalse(VersionCompare.isUpdate("1.0.0-beta", newerThan: "1.0.0"),
                       "beta 段按 0 → 不比 1.0.0 新")
        XCTAssertEqual(VersionCompare.compare("1.x.0", "1.0.0"), .orderedSame, "x 段按 0")
        // 变异证伪：segments 若 Int($0) ?? 0 改成强解包/抛错 → 非数字串崩，测试崩。
    }

    func testLeadingZerosNormalizeEqual() {
        XCTAssertEqual(VersionCompare.compare("01.02.03", "1.2.3"), .orderedSame, "前导零等价")
        XCTAssertFalse(VersionCompare.isUpdate("01.2.3", newerThan: "1.2.3"), "等价 → 不提示")
    }

    func testEmptyAndSingleVersion() {
        XCTAssertTrue(VersionCompare.isUpdate("0.0.1", newerThan: ""))   // "" → [0] 语义
        XCTAssertEqual(VersionCompare.compare("", ""), .orderedSame)
    }
}
