import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 契约测：**给 `keyEquivalent` 赋值不会顺带把修饰掩码设成 ⌘**（裸按钮与 NSAlert 按钮的默认掩码都是 0）。
///
/// 为什么值得钉住（这条是"有牙"的，不是空断言）：
/// 本仓有两处**手写、未显式清掩码**的键等价——
/// - `UpdateWindowController`：`upgradeButton.keyEquivalent = "\r"` / `laterButton.keyEquivalent = "\u{1b}"`
/// - `TransferProgressWindowController`：`cancelButton.keyEquivalent = "\u{1b}"`
///
/// 它们没写 `keyEquivalentModifierMask = []`。只要默认掩码是空，这就是裸 ⏎/裸 Esc；
/// 一旦哪天 SDK 改成默认带 ⌘（`AlertButtons.swift` 的历史注释就是这么写的——本测实测**证伪**了它），
/// 这两处会静默变成 ⌘⏎ / ⌘Esc，用户侧表现正是「⏎ 不确认、Esc 关不掉」。
/// 本测即那条结论的事实来源与守护者；`NSAlert.setDefaultConfirmCancel()` 显式清空掩码，不受此影响。
final class KeyEquivalentDefaultMaskTests: XCTestCase {
    func testAssigningKeyEquivalentLeavesModifierMaskEmpty() {
        let plain = NSButton(title: "x", target: nil, action: nil)
        XCTAssertEqual(plain.keyEquivalentModifierMask, [], "裸 NSButton 的默认掩码应为空")

        plain.keyEquivalent = "\u{1b}"
        XCTAssertEqual(plain.keyEquivalentModifierMask, [],
                       "赋值 keyEquivalent 不得顺带设成 ⌘——否则未清掩码的两处会静默变成 ⌘Esc")

        let alert = NSAlert()
        let first = alert.addButton(withTitle: "AAA")
        first.keyEquivalent = "\r"
        XCTAssertEqual(first.keyEquivalentModifierMask, [], "NSAlert 按钮同理")
    }

    /// 附带事实（三条都是本机实测，与文件头的"旧注释声称"相反，故值得钉住）：
    /// 1. `NSAlert` 自动给第 1 个按钮挂 `"\r"`；
    /// 2. 标题**不是**取消文案的第 2 按钮，什么都不挂（`""`）；
    /// 3. 标题**是**取消文案的按钮会被自动挂上 `"\u{1b}"`——**在** `setDefaultConfirmCancel()`
    ///    之前就挂了。即本机 SDK 下"裸 Esc 关不掉"并非因为缺 Esc 键等价。
    /// `setDefaultConfirmCancel()` 于是对 Esc 是幂等的再确认（顺带保证掩码为空），
    /// 对没有取消标题按钮的框则什么也不做——那类框的 Esc 走 NSAlert 默认行为。
    func testAlertAutoKeyEquivalents() {
        let alert = NSAlert()
        let first = alert.addButton(withTitle: "AAA")
        let second = alert.addButton(withTitle: "BBB")
        XCTAssertEqual(first.keyEquivalent, "\r", "第 1 按钮自动挂 ⏎")
        XCTAssertEqual(second.keyEquivalent, "", "非取消标题的第 2 按钮应什么都不挂")

        let withCancel = NSAlert()
        _ = withCancel.addButton(withTitle: L10n.t(.okBtn))
        let cancel = withCancel.addButton(withTitle: L10n.t(.cancelBtn))
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}",
                       "取消标题的按钮由 NSAlert 自动挂 Esc（在 setDefaultConfirmCancel 之前）")

        withCancel.setDefaultConfirmCancel()
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}", "收口后仍是 Esc")
        XCTAssertEqual(cancel.keyEquivalentModifierMask, [], "且掩码必须为空，才是裸 Esc")
    }
}
