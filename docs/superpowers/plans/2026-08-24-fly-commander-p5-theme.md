# FlyCommander P5 · 主题（Theme）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 FlyCommander 加一个可持久化的主题系统，控制三件事：外观（浅色/深色/跟随系统）、强调色（标记行底色 + 活动窗格边框）、按扩展名给文件名上色。

**Architecture:** TCCore 加纯 Swift 的 `Theme` 模型 + 纯函数分类器（`fileExtension`/`matchFileColorRule`，零 AppKit，可单测）；FlyCommander 加 `ThemeStore`（单例，UserDefaults+JSON 持久化，仿 `ConnectionStore`，NSColor 解析 + 外观应用）+ 一个主题窗（外观 segmented + 强调色 colorWell + 竖排自绘规则行 + 恢复默认）。视图层 `FileCellView`/`PaneTableView` 改读 `ThemeStore`；菜单/工具栏/命令栏三入口。

**Tech Stack:** Swift 5.9、AppKit、SwiftUI 无（纯 AppKit）、SPM 测试 + XCUITest。依赖仅既有的 Traversio（本计划不动）。

**Spec:** `docs/superpowers/specs/2026-08-24-fly-commander-p5-theme-design.md`

## Global Constraints

- **分层铁律**：TCCore 零 AppKit（纯 Foundation）；AppKit 只在 FlyCommander。`Theme` 模型用中性 `ThemeColor`（RGBA 结构体），绝不在 TCCore 引 NSColor。
- **缩减版 SDK**（写 AppKit 前必看 memory `reduced-sdk-environment`）：
  - 程序化子视图一律 `translatesAutoresizingMaskIntoConstraints = false`，否则整窗压成 12pt 宽。
  - NSView 子类：`let` 存储属性用隐式解包 `var ...!`，delegate/target/action 在 `super.init` 之后 wire。
  - **全程不创建 `DispatchQueue`**（动态建队会段错误）。本计划不需要任何队列。
  - `NSColorWell` 用 `isBordered` + `target`/`action`（点选触发 action）。
  - `NSSegmentedControl` 用 `init()` + `segmentCount` + `setLabel:forSegment:` 手动建（不赌便利 init）。
- **持久化**：UserDefaults + JSON，键 `"theme"`，仿 `ConnectionStore.persistRecent`（`JSONEncoder/Decoder`）。
- **单测隔离**：`ThemeStore` 测试用注入的 `UserDefaults(suiteName:)` 独立 suite；不污染 `.standard`。
- **测试命令**：SPM `swift test`（或单类 `swift test --filter ThemeTests`、单方法 `swift test --filter 'ThemeTests/testFileExtension'`）；XCUITest 用 `xcodegen generate && xcodebuild test -scheme FlyCommander -destination 'platform=macOS'`（需辅助功能授权；`xcodebuild ... | tail` 会吞退出码，看输出里的 `** TEST SUCCEEDED/FAILED **`）。
- **提交**：中文提交信息，格式 `feat: <中文描述>`（对齐 git log 风格）。

---

### Task 1: TCCore 主题模型 + 纯函数分类器

**Files:**
- Create: `Sources/TCCore/Theme/Theme.swift`
- Test: `Tests/TCCoreTests/ThemeTests.swift`

**Interfaces:**
- Produces（后续 task 依赖）：
  - `ThemeColor`（`Codable, Equatable`），字段 `red/green/blue/alpha: Double`，`init(red:green:blue:alpha: = 1)`。
  - `FileColorRule`（`Codable, Equatable`），字段 `extensions: [String]`、`color: ThemeColor`。
  - `Theme`（`Codable, Equatable`），字段 `appearance: Appearance`、`accent: ThemeColor`、`fileColorRules: [FileColorRule]`；嵌套 `enum Appearance: String, Codable, CaseIterable { case system, light, dark }`；`static let `default`: Theme`。
  - `func fileExtension(_ name: String) -> String?`
  - `func matchFileColorRule(_ item: FileItem, rules: [FileColorRule]) -> FileColorRule?`

- [ ] **Step 1: 写失败测试**

创建 `Tests/TCCoreTests/ThemeTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ThemeTests`
Expected: 编译失败（`Theme`/`ThemeColor`/`FileColorRule`/`fileExtension`/`matchFileColorRule` 未定义）。

- [ ] **Step 3: 实现 TCCore 主题模型**

创建 `Sources/TCCore/Theme/Theme.swift`：

```swift
import Foundation

/// 中性颜色（RGBA，TCCore 零 AppKit，不依赖 NSColor）。
public struct ThemeColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

/// 一条"扩展名集合 → 颜色"的文件上色规则。
public struct FileColorRule: Codable, Equatable {
    public var extensions: [String]   // 小写、不含点（如 ["png","jpg"]）
    public var color: ThemeColor

    public init(extensions: [String], color: ThemeColor) {
        self.extensions = extensions
        self.color = color
    }
}

public struct Theme: Codable, Equatable {
    public enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    public var appearance: Appearance
    public var accent: ThemeColor
    public var fileColorRules: [FileColorRule]

    public init(appearance: Appearance, accent: ThemeColor, fileColorRules: [FileColorRule]) {
        self.appearance = appearance
        self.accent = accent
        self.fileColorRules = fileColorRules
    }

    /// 出厂主题：跟随系统 + 系统蓝强调色 + 预置文件类型规则。
    public static let `default` = Theme(
        appearance: .system,
        accent: ThemeColor(red: 0.0, green: 0.478, blue: 1.0),
        fileColorRules: [
            FileColorRule(extensions: ["txt","md","log","swift","py","js","ts","json","xml","yml","yaml","sh","c","h","html","css","sql"],
                          color: ThemeColor(red: 0.25, green: 0.4, blue: 0.6)),
            FileColorRule(extensions: ["png","jpg","jpeg","gif","heic","webp","svg","bmp","tiff"],
                          color: ThemeColor(red: 0.1, green: 0.6, blue: 0.2)),
            FileColorRule(extensions: ["mp4","mov","mkv","avi","webm"],
                          color: ThemeColor(red: 0.5, green: 0.3, blue: 0.7)),
            FileColorRule(extensions: ["mp3","wav","flac","m4a","aac","ogg"],
                          color: ThemeColor(red: 0.9, green: 0.5, blue: 0.1)),
            FileColorRule(extensions: ["zip","tar","gz","bz2","7z","rar"],
                          color: ThemeColor(red: 0.6, green: 0.4, blue: 0.2)),
        ]
    )
}

/// 提取文件扩展名（小写、不含点）；无扩展名 / 纯点 / 尾点返回 nil。
public func fileExtension(_ name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return nil }
    let ext = name[name.index(after: dot)...].lowercased()
    return ext.isEmpty ? nil : ext
}

/// 命中首条扩展名规则即返回；目录 / 无扩展名返回 nil。
public func matchFileColorRule(_ item: FileItem, rules: [FileColorRule]) -> FileColorRule? {
    guard !item.isDirectory else { return nil }
    guard let ext = fileExtension(item.name) else { return nil }
    return rules.first { $0.extensions.contains(ext) }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ThemeTests`
Expected: PASS（5 个方法全绿）。

- [ ] **Step 5: 全量 SPM 冒烟 + 提交**

Run: `swift test`
Expected: 全绿（原 244 + 5 新）。

```bash
git add Sources/TCCore/Theme/Theme.swift Tests/TCCoreTests/ThemeTests.swift
git commit -m "feat(theme): TCCore 主题模型 + 纯函数扩展名分类器"
```

---

### Task 2: ThemeStore（持久化 + 外观 + NSColor 解析）

**Files:**
- Create: `Sources/FlyCommander/Theme/ThemeStore.swift`
- Test: `Tests/FlyCommanderTests/ThemeStoreTests.swift`

**Interfaces:**
- Consumes: `Theme`/`ThemeColor`/`FileColorRule`/`matchFileColorRule`（Task 1）。
- Produces（后续 task 依赖）：
  - `final class ThemeStore`：`static let shared: ThemeStore`；`init(defaults: UserDefaults = .standard)`；`private(set) var theme: Theme`；`var didChange: (() -> Void)?`；`var accentColor: NSColor`；`func nameColor(for item: FileItem) -> NSColor`；`func update(_ newTheme: Theme)`；`func resetToDefault()`；`func applyAppearance()`。

- [ ] **Step 1: 写失败测试**

创建 `Tests/FlyCommanderTests/ThemeStoreTests.swift`：

```swift
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

    override func setUp() {
        let name = "fly.test.theme.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)!
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: suite.name!)
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ThemeStoreTests`
Expected: 编译失败（`ThemeStore` 未定义）。

- [ ] **Step 3: 实现 ThemeStore**

创建 `Sources/FlyCommander/Theme/ThemeStore.swift`：

```swift
import Foundation
import AppKit
import TCCore

/// 主题门面：持久化（UserDefaults+JSON，键 "theme"）+ 外观应用 + NSColor 解析。
/// 仿 ConnectionStore：单例 + 可注入 UserDefaults（单测用独立 suite，不碰 .standard）。
final class ThemeStore {
    static let shared = ThemeStore()

    private let defaults: UserDefaults
    private let storeKey = "theme"
    private(set) var theme: Theme

    /// 主题变化通知（MainViewController 订阅后刷新两窗格）。
    var didChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let t = try? JSONDecoder().decode(Theme.self, from: data) {
            self.theme = t
        } else {
            self.theme = .default
        }
        applyAppearance()
    }

    var accentColor: NSColor {
        NSColor(red: theme.accent.red, green: theme.accent.green,
                blue: theme.accent.blue, alpha: theme.accent.alpha)
    }

    /// 文件名文本色：命中规则→规则色；否则 labelColor（目录恒 labelColor）。
    func nameColor(for item: FileItem) -> NSColor {
        if let rule = matchFileColorRule(item, rules: theme.fileColorRules) {
            return NSColor(red: rule.color.red, green: rule.color.green,
                           blue: rule.color.blue, alpha: rule.color.alpha)
        }
        return .labelColor
    }

    func update(_ newTheme: Theme) {
        theme = newTheme
        persist()
        applyAppearance()
        didChange?()
    }

    func resetToDefault() { update(.default) }

    private func persist() {
        guard let data = try? JSONEncoder().encode(theme) else { return }
        defaults.set(data, forKey: storeKey)
    }

    /// 应用外观到整个 app（惰性 no-op，无 GUI 进程下安全）。
    func applyAppearance() {
        let app = NSApplication.shared
        switch theme.appearance {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ThemeStoreTests`
Expected: PASS（7 个方法全绿）。

- [ ] **Step 5: 全量 SPM 冒烟 + 提交**

Run: `swift test`
Expected: 全绿。

```bash
git add Sources/FlyCommander/Theme/ThemeStore.swift Tests/FlyCommanderTests/ThemeStoreTests.swift
git commit -m "feat(theme): ThemeStore 持久化 + 外观应用 + NSColor 解析"
```

---

### Task 3: 视图层改读 ThemeStore（FileCellView + PaneTableView）

**Files:**
- Modify: `Sources/FlyCommander/Panes/FileCellView.swift`（`configure` 方法）
- Modify: `Sources/FlyCommander/Panes/PaneTableView.swift`（`setActive` 方法）
- Test: `Tests/FlyCommanderTests/FileCellViewThemeTests.swift`

**Interfaces:**
- Consumes: `ThemeStore.shared.accentColor`、`ThemeStore.shared.nameColor(for:)`（Task 2）。

- [ ] **Step 1: 写失败测试（断言视图真的用了主题色）**

创建 `Tests/FlyCommanderTests/FileCellViewThemeTests.swift`：

```swift
import XCTest
import AppKit
@testable import FlyCommander
import TCCore

private func makeItem(_ name: String) -> FileItem {
    FileItem(id: "/\(name)", path: TCPath("/\(name)"), name: name, isDirectory: false,
             size: 1, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

final class FileCellViewThemeTests: XCTestCase {
    override func tearDown() {
        // 复原共享单例，避免污染同进程其它测试
        ThemeStore.shared.update(Theme.default)
    }

    func testMarkedRowBackgroundUsesAccent() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        let cell = FileCellView(frame: .zero)
        cell.configure(item: makeItem("a.txt"), focus: false, marked: true, column: 0)
        guard let bg = cell.layer?.backgroundColor else {
            return XCTFail("marked 行应有背景色")
        }
        let c = NSColor(cgColor: bg)
        XCTAssertGreaterThan(c.redComponent, c.blueComponent, "marked 底色应偏 accent(红)")
    }

    func testNameLabelUsesRuleColor() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 0, green: 0, blue: 0),
                                       fileColorRules: [FileColorRule(extensions: ["png"],
                                                                      color: ThemeColor(red: 0, green: 1, blue: 0))]))
        let cell = FileCellView(frame: .zero)
        cell.configure(item: makeItem("a.png"), focus: false, marked: false, column: 0)
        XCTAssertEqual(cell.nameLabel.textColor?.greenComponent ?? 0, 1, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter FileCellViewThemeTests`
Expected: `testMarkedRowBackgroundUsesAccent` FAIL（当前底色是 `controlAccentColor` 而非红色 accent）；`testNameLabelUsesRuleColor` FAIL（当前 normal 名字是 `labelColor` 而非规则绿）。

- [ ] **Step 3: 改 FileCellView.configure**

编辑 `Sources/FlyCommander/Panes/FileCellView.swift`，把 `configure` 末尾的高亮块
（现在约在第 75–88 行）替换为：

```swift
        if focus {
            nameLabel.textColor = .selectedControlTextColor
            nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        } else if marked {
            nameLabel.textColor = ThemeStore.shared.nameColor(for: item)
            nameLabel.font = .systemFont(ofSize: 12)
            layer?.backgroundColor = ThemeStore.shared.accentColor.withAlphaComponent(0.25).cgColor
        } else {
            nameLabel.textColor = ThemeStore.shared.nameColor(for: item)
            nameLabel.font = .systemFont(ofSize: 12)
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
```

- [ ] **Step 4: 改 PaneTableView.setActive**

编辑 `Sources/FlyCommander/Panes/PaneTableView.swift`，把 `setActive`（现在约第 97–101 行）：

```swift
    func setActive(_ active: Bool) {
        isActive = active
        layer?.borderColor = (active ? NSColor.systemBlue.cgColor : NSColor.separatorColor.cgColor)
        layer?.borderWidth = active ? 1 : 0.5
    }
```

改为：

```swift
    func setActive(_ active: Bool) {
        isActive = active
        layer?.borderColor = (active ? ThemeStore.shared.accentColor.cgColor : NSColor.separatorColor.cgColor)
        layer?.borderWidth = active ? 1 : 0.5
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter FileCellViewThemeTests`
Expected: PASS（2 个方法全绿）。

- [ ] **Step 6: 全量 SPM 冒烟 + 提交**

Run: `swift test`
Expected: 全绿（含既有 PaneTableViewTests / PaneSortTests——它们不依赖具体颜色，应不受影响）。

```bash
git add Sources/FlyCommander/Panes/FileCellView.swift Sources/FlyCommander/Panes/PaneTableView.swift Tests/FlyCommanderTests/FileCellViewThemeTests.swift
git commit -m "feat(theme): 视图层标记底色/文件名色/活动边框改读 ThemeStore"
```

---

### Task 4: 主题窗（外观 + 强调色 + 文件类型规则行）

**Files:**
- Create: `Sources/FlyCommander/Theme/ThemeWindowController.swift`
- Create: `Sources/FlyCommander/Theme/ThemeViewController.swift`（含自绘规则行 `FileColorRuleRowView`）
- Test: `Tests/FlyCommanderTests/ThemeViewControllerTests.swift`（纯函数：扩展名解析/外观索引/颜色转换）

**Interfaces:**
- Consumes: `ThemeStore.shared`（Task 2）；`Theme`/`FileColorRule`/`ThemeColor`（Task 1）。
- Produces：`ThemeWindowController`（`init()`、`func present()`）——Task 5 的入口用。
- `ThemeViewController` 静态纯函数：`parseExtensions(_:)`、`joinExtensions(_:)`、`appearanceIndex(_:)`、`appearanceFromIndex(_:)`、`colorWellToThemeColor(_:)`。

- [ ] **Step 1: 写失败测试（纯函数，不驱动 AppKit 窗口）**

创建 `Tests/FlyCommanderTests/ThemeViewControllerTests.swift`：

```swift
import XCTest
import AppKit
@testable import FlyCommander
import TCCore

final class ThemeViewControllerTests: XCTestCase {
    func testParseExtensions() {
        XCTAssertEqual(ThemeViewController.parseExtensions("png, jpg, GIF"), ["png", "jpg", "gif"])
        XCTAssertEqual(ThemeViewController.parseExtensions("txt"), ["txt"])
        XCTAssertEqual(ThemeViewController.parseExtensions(" a , , b ,"), ["a", "b"])
        XCTAssertEqual(ThemeViewController.parseExtensions(""), [])
    }

    func testJoinParseRoundTrip() {
        let exts = ["png", "jpg", "gif"]
        XCTAssertEqual(ThemeViewController.parseExtensions(ThemeViewController.joinExtensions(exts)), exts)
    }

    func testAppearanceIndexRoundTrip() {
        for a in Theme.Appearance.allCases {
            XCTAssertEqual(ThemeViewController.appearanceFromIndex(ThemeViewController.appearanceIndex(a)), a)
        }
    }

    func testColorWellToThemeColor() {
        let tc = ThemeViewController.colorWellToThemeColor(NSColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        XCTAssertEqual(tc.red, 0.25, accuracy: 0.01)
        XCTAssertEqual(tc.green, 0.5, accuracy: 0.01)
        XCTAssertEqual(tc.blue, 0.75, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ThemeViewControllerTests`
Expected: 编译失败（`ThemeViewController` 未定义）。

- [ ] **Step 3: 实现 ThemeWindowController**

创建 `Sources/FlyCommander/Theme/ThemeWindowController.swift`：

```swift
import AppKit

/// 主题窗（非模态，仿 SearchWindowController）。改即生效——各控件 action 直接写 ThemeStore。
final class ThemeWindowController: NSWindowController {
    private let themeVC = ThemeViewController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "主题"
        window.contentViewController = themeVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        _ = themeVC.view   // 强制 loadView 执行（否则 appearanceSegment 等 var...! 尚未 wire，reload 会解引用 nil 崩溃）
        themeVC.reload()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 4: 实现 ThemeViewController + 自绘规则行**

创建 `Sources/FlyCommander/Theme/ThemeViewController.swift`：

```swift
import AppKit
import TCCore

final class ThemeViewController: NSViewController {
    private var appearanceSegment: NSSegmentedControl!
    private var accentWell: NSColorWell!
    private var rulesStack: NSStackView!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 640))

        // 外层竖排容器
        let container = NSStackView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.distribution = .fill

        // 1) 外观
        let appearanceLabel = NSTextField(labelWithString: "外观")
        appearanceLabel.translatesAutoresizingMaskIntoConstraints = false
        let segment = NSSegmentedControl(frame: .zero)
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.segmentCount = 3
        segment.trackingMode = .selectOne
        segment.setLabel("跟随系统", forSegment: 0)
        segment.setLabel("浅色", forSegment: 1)
        segment.setLabel("深色", forSegment: 2)
        segment.target = self
        segment.action = #selector(appearanceChanged(_:))
        appearanceSegment = segment

        // 2) 强调色
        let accentLabel = NSTextField(labelWithString: "强调色（标记行底色 / 活动窗格边框）")
        accentLabel.translatesAutoresizingMaskIntoConstraints = false
        let well = NSColorWell(frame: .zero)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.isBordered = true
        well.target = self
        well.action = #selector(accentChanged(_:))
        accentWell = well

        // 3) 文件类型配色（标题 + 滚动列表 + 添加按钮）
        let rulesLabel = NSTextField(labelWithString: "文件类型配色（扩展名逗号分隔；编辑后按回车生效）")
        rulesLabel.translatesAutoresizingMaskIntoConstraints = false

        let rulesScroll = NSScrollView()
        rulesScroll.translatesAutoresizingMaskIntoConstraints = false
        rulesScroll.hasVerticalScroller = true
        rulesScroll.hasHorizontalScroller = false
        rulesScroll.autohidesScrollers = true
        let stack = NSStackView(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        rulesStack = stack
        rulesScroll.documentView = stack
        // documentView 只钉 top/leading/trailing，不钉 bottom：内容超高时纵向可滚动。
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: rulesScroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: rulesScroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rulesScroll.contentView.trailingAnchor),
        ])

        let addBtn = NSButton(title: "添加规则", target: self, action: #selector(addRule))
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        // 恢复默认
        let restoreBtn = NSButton(title: "恢复默认", target: self, action: #selector(restoreDefault))
        restoreBtn.translatesAutoresizingMaskIntoConstraints = false

        [appearanceLabel, segment, accentLabel, well, rulesLabel, rulesScroll, addBtn, restoreBtn]
            .forEach { container.addArrangedSubview($0) }
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            rulesScroll.widthAnchor.constraint(equalTo: container.widthAnchor),
            rulesScroll.heightAnchor.constraint(equalToConstant: 300),
        ])

        self.view = root
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    init() { super.init(nibName: nil, bundle: nil) }

    /// 打开窗口时从 ThemeStore 读当前值刷新控件。
    func reload() {
        appearanceSegment.selectedSegment = Self.appearanceIndex(ThemeStore.shared.theme.appearance)
        accentWell.color = ThemeStore.shared.accentColor
        for sub in rulesStack.arrangedSubviews { rulesStack.removeArrangedSubview(sub); sub.removeFromSuperview() }
        for rule in ThemeStore.shared.theme.fileColorRules {
            rulesStack.addArrangedSubview(Self.makeRuleRow(rule))
        }
    }

    // MARK: - 控件 action

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        var t = ThemeStore.shared.theme
        t.appearance = Self.appearanceFromIndex(sender.selectedSegment)
        ThemeStore.shared.update(t)
    }

    @objc private func accentChanged(_ sender: NSColorWell) {
        var t = ThemeStore.shared.theme
        t.accent = Self.colorWellToThemeColor(sender.color)
        ThemeStore.shared.update(t)
    }

    @objc private func addRule() {
        var t = ThemeStore.shared.theme
        let color = t.fileColorRules.first?.color ?? ThemeColor(red: 0, green: 0, blue: 0)
        t.fileColorRules.append(FileColorRule(extensions: ["txt"], color: color))
        ThemeStore.shared.update(t)
        reload()
    }

    @objc private func restoreDefault() {
        ThemeStore.shared.resetToDefault()
        reload()
    }

    // MARK: - 规则行 ↔ theme

    static func makeRuleRow(_ rule: FileColorRule) -> FileColorRuleRowView {
        let row = FileColorRuleRowView(frame: .zero)
        row.extField.stringValue = joinExtensions(rule.extensions)
        row.colorWell.color = NSColor(red: rule.color.red, green: rule.color.green,
                                      blue: rule.color.blue, alpha: rule.color.alpha)
        row.onExtensionChange = { [weak self] in self?.ruleChanged() }
        row.onColorChange = { [weak self] in self?.ruleChanged() }
        row.onDelete = { [weak self] in self?.deleteRuleRow(row) }
        return row
    }

    private func ruleChanged() {
        var t = ThemeStore.shared.theme
        t.fileColorRules = currentRules()
        ThemeStore.shared.update(t)
    }

    private func currentRules() -> [FileColorRule] {
        rulesStack.arrangedSubviews.compactMap { $0 as? FileColorRuleRowView }.map { row in
            FileColorRule(extensions: Self.parseExtensions(row.extField.stringValue),
                          color: Self.colorWellToThemeColor(row.colorWell.color))
        }
    }

    private func deleteRuleRow(_ row: FileColorRuleRowView) {
        rulesStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        ruleChanged()
    }

    // MARK: - 纯函数（可单测）

    static func parseExtensions(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func joinExtensions(_ exts: [String]) -> String { exts.joined(separator: ", ") }

    static func appearanceIndex(_ a: Theme.Appearance) -> Int {
        switch a { case .system: return 0; case .light: return 1; case .dark: return 2 }
    }

    static func appearanceFromIndex(_ i: Int) -> Theme.Appearance {
        switch i { case 1: return .light; case 2: return .dark; default: return .system }
    }

    static func colorWellToThemeColor(_ c: NSColor) -> ThemeColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return ThemeColor(red: Double(s.redComponent), green: Double(s.greenComponent),
                          blue: Double(s.blueComponent), alpha: Double(s.alphaComponent))
    }
}

/// 一条文件类型规则行：扩展名文本框 + 取色器 + 删除按钮。
final class FileColorRuleRowView: NSView {
    private(set) let extField = NSTextField()
    private(set) let colorWell = NSColorWell(frame: .zero)
    private(set) let deleteButton = NSButton(title: "×", target: nil, action: nil)

    var onDelete: (() -> Void)?
    var onExtensionChange: (() -> Void)?
    var onColorChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        extField.translatesAutoresizingMaskIntoConstraints = false
        extField.placeholderString = "png, jpg, gif"
        extField.target = self
        extField.action = #selector(extChanged)

        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.isBordered = true
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.title = "×"
        deleteButton.bezelStyle = .roundRect
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)

        [extField, colorWell, deleteButton].forEach { addSubview($0) }
        NSLayoutConstraint.activate([
            extField.leadingAnchor.constraint(equalTo: leadingAnchor),
            extField.centerYAnchor.constraint(equalTo: centerYAnchor),
            extField.widthAnchor.constraint(equalToConstant: 210),
            colorWell.leadingAnchor.constraint(equalTo: extField.trailingAnchor, constant: 8),
            colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            deleteButton.leadingAnchor.constraint(equalTo: colorWell.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func extChanged() { onExtensionChange?() }
    @objc private func colorChanged() { onColorChange?() }
    @objc private func deleteTapped() { onDelete?() }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter ThemeViewControllerTests`
Expected: PASS（4 个方法全绿）。

- [ ] **Step 6: 全量 SPM 冒烟 + 提交**

Run: `swift test`
Expected: 全绿。

```bash
git add Sources/FlyCommander/Theme/ThemeWindowController.swift Sources/FlyCommander/Theme/ThemeViewController.swift Tests/FlyCommanderTests/ThemeViewControllerTests.swift
git commit -m "feat(theme): 主题窗（外观/强调色/文件类型规则行，改即生效）"
```

---

### Task 5: 入口接线（菜单 + 工具栏 + 命令栏 + MainViewController）

**Files:**
- Modify: `Sources/FlyCommander/App/MainViewController.swift`（持有 themeWindow、订阅 didChange、`menuTheme`、接 `onOpenTheme`）
- Modify: `Sources/FlyCommander/App/MainMenu.swift`（查看菜单加"主题…"）
- Modify: `Sources/FlyCommander/App/MainWindowController.swift`（工具栏加"主题"）
- Modify: `Sources/FlyCommander/Command/InternalCommandExecutor.swift`（`theme` 命令 + `onOpenTheme` 钩子 + helpText）
- Test: `Tests/FlyCommanderTests/InternalCommandExecutorTests.swift`（加 `theme` 命令 + harness 钩子）

**Interfaces:**
- Consumes: `ThemeWindowController`（Task 4）、`ThemeStore.shared`（Task 2）。

- [ ] **Step 1: 改测试 harness + 加 theme 命令失败测试**

编辑 `Tests/FlyCommanderTests/InternalCommandExecutorTests.swift`：

(a) 在 `Harness` 里加字段与接线。把（现在约第 51–69 行）：

```swift
    var viewItem: FileItem?
    var editItem: FileItem?
```

之后加一行：

```swift
    var themeOpened = 0
```

并在 `init` 里（`exec.onEdit = ...` 那行之后，现在约第 68 行）加：

```swift
        exec.onOpenTheme = { [weak self] in self?.themeOpened += 1 }
```

(b) 把 `testHelpListsCommands` 的关键词数组（现在约第 105 行）：

```swift
        for kw in ["cd", "ls", "mkdir", "copy", "move", "del", "view", "edit", "sftp", "help"] {
```

改为加 `"theme"`：

```swift
        for kw in ["cd", "ls", "mkdir", "copy", "move", "del", "view", "edit", "sftp", "theme", "help"] {
```

(c) 在文件末尾（`testMoveDelegatesToWorkspaceHook` 之后、类闭括号前）加测试：

```swift
    func testThemeCommandOpensWindow() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "theme")
        XCTAssertEqual(h.themeOpened, 1)
        XCTAssertEqual(out, "已打开主题窗")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter InternalCommandExecutorTests`
Expected: 编译失败（`onOpenTheme` 未定义）；即便加上了，`testThemeCommandOpensWindow` FAIL（无 `theme` case）。

- [ ] **Step 3: 改 InternalCommandExecutor**

编辑 `Sources/FlyCommander/Command/InternalCommandExecutor.swift`：

(a) 在 `var onConnectSFTP` 之后（现在约第 20 行）加：

```swift
    /// theme 命令入口（弹主题窗）。
    var onOpenTheme: (() -> Void)?
```

(b) 在 `helpText` 数组里（`"  sftp [host[:port]] ..."` 那行之后）加：

```swift
        "  theme                打开主题窗（外观/强调色/文件类型配色）",
```

(c) 在 `execute` 的 `switch` 里（`case "sftp":` 之后）加：

```swift
        case "theme": onOpenTheme?(); return "已打开主题窗"
```

- [ ] **Step 4: 改 MainViewController**

编辑 `Sources/FlyCommander/App/MainViewController.swift`：

(a) 在 `private let connectionWindow = ConnectionWindowController()`（现在约第 12 行）之后加：

```swift
    private let themeWindow = ThemeWindowController()
```

(b) 在 `loadView` 里、`commandExecutor` 的 `onConnectSFTP` 接线之后（现在约第 73 行之后）加两行：

```swift
        commandExecutor.onOpenTheme = { [weak self] in self?.themeWindow.present() }
        ThemeStore.shared.didChange = { [weak self] in
            self?.leftPaneView.reload(); self?.rightPaneView.reload()
        }
```

(c) 在菜单 action 区（`@objc func menuConnect(_ sender: Any?) { beginConnection() }`，现在约第 215 行）之后加：

```swift
    @objc func menuTheme(_ sender: Any?) { themeWindow.present() }
```

- [ ] **Step 5: 改 MainMenu（查看菜单加"主题…"）**

编辑 `Sources/FlyCommander/App/MainMenu.swift`，在查看菜单（现在约第 51 行 `add(viewMenu, "上级目录", ...)` 之后）加：

```swift
        add(viewMenu, "主题…", #selector(MainViewController.menuTheme(_:)), "", target)
```

- [ ] **Step 6: 改 MainWindowController（工具栏加"主题"）**

编辑 `Sources/FlyCommander/App/MainWindowController.swift`：

(a) 在 `NSToolbarItem.Identifier` 扩展里（`static let connect = ...`，现在约第 10 行）之后加：

```swift
    static let theme = NSToolbarItem.Identifier("theme")
```

(b) 在 `toolbar(_:itemForItemIdentifier:...)` 的 `switch` 里（`case .connect:` 之后）加：

```swift
        case .theme:
            return item(id: .theme, label: "主题", symbol: "paintpalette",
                        action: #selector(MainViewController.menuTheme(_:)))
```

(c) 把 `toolbarDefaultItemIdentifiers`（现在约第 95–98 行）改为：

```swift
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.copy, .move, .makeDirectory, .delete, .rename, .search, .connect, .theme,
         .space, .selectionStatus]
    }
```

(d) 把 `toolbarAllowedItemIdentifiers`（现在约第 100–103 行）改为：

```swift
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.copy, .move, .makeDirectory, .delete, .rename, .search, .connect, .theme,
         .selectionStatus, .space]
    }
```

- [ ] **Step 7: 跑测试确认通过**

Run: `swift test --filter InternalCommandExecutorTests`
Expected: PASS（含新 `testThemeCommandOpensWindow` 与更新后的 `testHelpListsCommands`）。

- [ ] **Step 8: 全量 SPM 冒烟 + 提交**

Run: `swift test`
Expected: 全绿。

```bash
git add Sources/FlyCommander/App/MainViewController.swift Sources/FlyCommander/App/MainMenu.swift Sources/FlyCommander/App/MainWindowController.swift Sources/FlyCommander/Command/InternalCommandExecutor.swift Tests/FlyCommanderTests/InternalCommandExecutorTests.swift
git commit -m "feat(theme): 主题三入口（菜单/工具栏/命令栏）+ 订阅刷新"
```

---

### Task 6: XCUITest（主题窗可打开 + 控件齐全）

**Files:**
- Modify: `UITests/FlyCommanderUITests.swift`

**Interfaces:**
- Consumes: 工具栏"主题"按钮、菜单"查看→主题…"、标题为"主题"的窗口（Task 5）。
- 说明：持久化（外观/规则跨重启）由 SPM `ThemeStoreTests` 覆盖；XCUITest 下 app 的 appearance / UserDefaults 无法经 AX 稳定观测，故 UI 层只断言窗口打开 + 控件齐全。跨重启外观的目测验证在"手动验证"节。

- [ ] **Step 1: 加两条 XCUITest**

在 `UITests/FlyCommanderUITests.swift` 的 `testSearchFlowFindsFiles` 之后（"// MARK: - 预览" 之前，现在约第 272 行附近）加：

```swift
    // MARK: - 主题窗（持久化由 SPM ThemeStoreTests 覆盖；此处只验窗口与控件）

    private func themeWindow() -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == '主题'")).firstMatch
    }

    func testThemeWindowOpensViaMenu() {
        menuBar("查看").click()
        menuBar("查看").menuItems
            .matching(NSPredicate(format: "title == '主题…'")).firstMatch.click()
        let win = themeWindow()
        XCTAssertTrue(win.waitForExistence(timeout: 5), "主题窗未弹出")
        // 关键控件：外观 segmented（3 段）、强调色取色器、规则行、添加/恢复按钮
        XCTAssertTrue(win.buttons.matching(NSPredicate(format: "title == '添加规则'")).firstMatch.exists, "缺 添加规则")
        XCTAssertTrue(win.buttons.matching(NSPredicate(format: "title == '恢复默认'")).firstMatch.exists, "缺 恢复默认")
        // 默认主题带 5 条预置规则 → 至少 5 个扩展名输入框（textFields 已验证）；
        // 不取色器断言（colorWells 在缩减版 XCUITest SDK 未验证）。
        XCTAssertGreaterThanOrEqual(win.textFields.count, 5, "缺 文件类型规则行")
    }

    func testThemeWindowOpensViaToolbar() {
        toolbarButton("主题").click()
        let win = themeWindow()
        XCTAssertTrue(win.waitForExistence(timeout: 5), "工具栏 主题 未弹出主题窗")
        XCTAssertTrue(win.buttons.matching(NSPredicate(format: "title == '添加规则'")).firstMatch.exists, "缺 添加规则")
    }
```

- [ ] **Step 2: 重新生成工程 + 跑 XCUITest**

Run:
```bash
xcodegen generate
xcodebuild test -scheme FlyCommander -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: 输出含 `** TEST SUCCEEDED **`，且新增两条主题用例通过。
注意：`xcodebuild ... | tail` 会吞退出码，只看输出里的 `** TEST SUCCEEDED/FAILED **`。需本机已授予辅助功能权限。

- [ ] **Step 3: 提交**

```bash
git add UITests/FlyCommanderUITests.swift
git commit -m "test(theme): XCUITest 主题窗（菜单/工具栏打开 + 控件齐全）"
```

---

### 手动验证（实现完成后，`swift run FlyCommander` 目测）

1. **外观**：菜单"查看→主题…"或工具栏"主题"打开主题窗；外观 segmented 切"深色"→整窗格即时转深色；重启 app 仍深色。
2. **强调色**：取色器选红色 → 用空格标记一个文件，标记行底色应为半透明红；切窗格（Tab）后活动窗格边框应为红。
3. **文件类型上色**：默认预置下，`alpha_small.txt`（txt）名字应为蓝灰、`large.bin`（无规则）为默认色、图片文件名为绿。手动加一条 `bin` → 某色的规则、按回车，`.bin` 文件立即变色；删除该行恢复。
4. **恢复默认**：改乱后点"恢复默认"，三维度回到出厂值。
5. **命令栏**：焦点在文件列表输入 `theme` + 回车 → 主题窗弹出，命令栏回显"已打开主题窗"。
6. **持久化**：改外观/强调色/加规则 → 重启 app，全部保留。
7. 全量回归：`swift test`（SPM 全绿）+ 上面 Step 2 的 XCUITest（含既有用例不回归）。
