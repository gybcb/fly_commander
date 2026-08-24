import XCTest
import AppKit
@testable import FlyCommander
import TCCore

private func makeItem(_ name: String, dir: Bool = false) -> FileItem {
    FileItem(id: "/\(name)", path: TCPath("/\(name)"), name: name, isDirectory: dir,
             size: 1, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

final class ThemeStoreTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "fly.test.theme.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
    }

    func testFallsBackToDefaultWhenNoStoredTheme() {
        XCTAssertEqual(ThemeStore(defaults: suite).theme, Theme.default)
    }

    func testPersistAndReload() {
        let store = ThemeStore(defaults: suite)
        let t = Theme(appearance: .dark, accent: ThemeColor(red: 0.5, green: 0.5, blue: 0.5),
                      fileColorRules: [FileColorRule(extensions: ["x"],
                                                     color: ThemeColor(red: 1, green: 0, blue: 0))])
        store.update(t)
        XCTAssertEqual(ThemeStore(defaults: suite).theme, t, "持久化后新实例应读回同值")
    }

    func testDidChangeFiresOnUpdate() {
        let store = ThemeStore(defaults: suite)
        var fired = 0
        store.didChange = { fired += 1 }
        store.update(Theme.default)
        XCTAssertEqual(fired, 1)
    }

    func testAccentColorResolution() {
        let store = ThemeStore(defaults: suite)
        store.update(Theme(appearance: .system, accent: ThemeColor(red: 1, green: 0, blue: 0),
                           fileColorRules: []))
        let c = store.accentColor
        XCTAssertEqual(c.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(c.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(c.blueComponent, 0, accuracy: 0.01)
    }

    func testNameColorRuleHit() {
        let store = ThemeStore(defaults: suite)
        store.update(Theme(appearance: .system, accent: ThemeColor(red: 0, green: 0, blue: 0),
                           fileColorRules: [FileColorRule(extensions: ["png"],
                                                          color: ThemeColor(red: 0, green: 1, blue: 0))]))
        XCTAssertEqual(store.nameColor(for: makeItem("a.png")).greenComponent, 1, accuracy: 0.01)
    }

    func testNameColorRuleMissIsLabelColor() {
        let store = ThemeStore(defaults: suite)
        store.update(Theme(appearance: .system, accent: ThemeColor(red: 0, green: 0, blue: 0),
                           fileColorRules: [FileColorRule(extensions: ["png"],
                                                          color: ThemeColor(red: 0, green: 1, blue: 0))]))
        XCTAssertEqual(store.nameColor(for: makeItem("a.xyz")), NSColor.labelColor)
    }

    func testDirectoryNameColorIsLabelColor() {
        let store = ThemeStore(defaults: suite)
        store.update(Theme(appearance: .system, accent: ThemeColor(red: 0, green: 0, blue: 0),
                           fileColorRules: [FileColorRule(extensions: ["png"],
                                                          color: ThemeColor(red: 0, green: 1, blue: 0))]))
        XCTAssertEqual(store.nameColor(for: makeItem("a.png", dir: true)), NSColor.labelColor)
    }
}
