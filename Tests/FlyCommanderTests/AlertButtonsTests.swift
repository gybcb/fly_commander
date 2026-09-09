import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// NSAlert.setDefaultConfirmCancel 回归：主按钮 ⏎、取消键 Esc、掩码清空。
/// 可证伪性：删掉扩展里的 keyEquivalent 赋值 → 前两条红；
/// 删掉 keyEquivalentModifierMask=[] → 第三条红（NSAlert 取消键默认带 ⌘ 掩码）。
final class AlertButtonsTests: XCTestCase {

    private func makeAlert(titles: [String]) -> NSAlert {
        let alert = NSAlert()
        titles.forEach { alert.addButton(withTitle: $0) }
        return alert
    }

    func testConfirmButtonGetsReturnKey() {
        let alert = makeAlert(titles: [L10n.t(.deleteWord), L10n.t(.cancelBtn)])
        alert.setDefaultConfirmCancel()
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons.first?.keyEquivalentModifierMask, [])
    }

    func testCancelButtonGetsEscapeKey() {
        let alert = makeAlert(titles: [L10n.t(.deleteWord), L10n.t(.cancelBtn)])
        alert.setDefaultConfirmCancel()
        let cancel = alert.buttons.last
        XCTAssertEqual(cancel?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(cancel?.keyEquivalentModifierMask, [])
    }

    /// 冲突框形态（5 键无 accessory 场景）：只动第 1 与「取消」，中间键不受影响。
    func testConflictAlertOnlyTouchesFirstAndCancel() {
        let alert = makeAlert(titles: [L10n.t(.overwrite), L10n.t(.skip), L10n.t(.overwriteAll),
                                       L10n.t(.skipAll), L10n.t(.cancelBtn)])
        let middleBefore = alert.buttons[1...3].map(\.keyEquivalent)
        alert.setDefaultConfirmCancel()
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[4].keyEquivalent, "\u{1b}")
        XCTAssertEqual(alert.buttons[1...3].map(\.keyEquivalent), middleBefore,
                       "中间三个按钮的 keyEquivalent 必须原样保留")
    }

    /// 无「取消」文案按钮时（理论上不存在此调用点），不得 trap、第 1 按钮仍拿 ⏎。
    func testAlertWithoutCancelButtonStillSetsDefault() {
        let alert = makeAlert(titles: [L10n.t(.okBtn)])
        alert.setDefaultConfirmCancel()
        XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\r")
    }
}
