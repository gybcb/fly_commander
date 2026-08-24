# FlyCommander P5 · 主题（Theme）设计

日期：2026-08-24
状态：设计已确认，待实现计划

## 背景与目标

P5 = 多标签 + 视图模式 + 目录热键 + 主题，四个独立子系统，拆成 4 个子周期逐个交付
（每个周期独立 设计→spec→plan→实现→验证，每次保持全绿构建）。本文是**第一个子周期：主题**。

背景约束：原生重构（2026-08-22）已把界面改为 macOS 原生风格、全部用系统色、随系统明暗自适应，
TC 经典 navy 配色已作废。因此"主题"不是恢复 TC 配色，而是在系统色基线上叠加一层**可持久化的
个性化偏好**。

**主题控制三个维度**（已与用户确认；**行密度不在范围**）：

1. **外观** — 强制 浅色 / 深色 / 跟随系统（当前只能跟随系统）。
2. **强调色** — 自定义强调色，替代系统 `controlAccentColor` 在"标记行底色"和"活动窗格边框"上的用法。
3. **文件类型上色** — 按扩展名给文件名文本上色（spec 里预留的 `FileVisualRole` 扩展点）。

## 架构（遵守 TCCore 纯 / FlyCommander 薄 的分层）

### TCCore（纯 Swift，零 AppKit）— `Sources/TCCore/Theme/Theme.swift`

中性颜色用 RGBA 结构体（TCCore 无 AppKit，不依赖 NSColor）。

```swift
public struct ThemeColor: Codable, Equatable {
    public var red: Double; public var green: Double
    public var blue: Double; public var alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) { ... }
}

public struct FileColorRule: Codable, Equatable {
    public var extensions: [String]   // 小写、不含点（如 ["png","jpg"]）
    public var color: ThemeColor
}

public struct Theme: Codable, Equatable {
    public enum Appearance: String, Codable, CaseIterable { case system, light, dark }
    public var appearance: Appearance
    public var accent: ThemeColor
    public var fileColorRules: [FileColorRule]

    public static let `default` = Theme(
        appearance: .system,
        accent: <系统强调色等价的固定 RGB，如 (0.0, 0.478, 1.0) 系统蓝>,
        fileColorRules: <出厂预置规则，见下>
    )
}
```

纯函数（可单测，是核心判定逻辑）：

```swift
/// 提取文件扩展名（小写、不含点）；无扩展名/纯点文件返回 nil。
/// ".gitignore" → nil（只有一个点）；"a.TAR.gz" → "gz"；"readme" → nil；"a." → nil。
public func fileExtension(_ name: String) -> String?

/// 命中首条扩展名规则即返回；目录返回 nil（目录不上色，靠图标区分）。
public func matchFileColorRule(_ item: FileItem, rules: [FileColorRule]) -> FileColorRule?
```

### FlyCommander（AppKit 层）— `Sources/FlyCommander/Theme/`

- **`ThemeStore`**（单例，仿 `ConnectionStore.shared`）：
  - `init(defaults: UserDefaults = .standard)`，UserDefaults 可注入（单测用独立 suite）。
  - `private(set) var theme: Theme`；键 `"theme"`，JSON 持久化（仿 `ConnectionStore.persistRecent`）。
  - `didChange: (() -> Void)?` — 主题变化通知，`MainViewController` 订阅后刷新两窗格。
  - `update(_ theme: Theme)` — 赋值 → 持久化 → 应用外观 → 触发 `didChange`。
  - `applyAppearance()` — `NSApplication.shared.appearance = nil / .aqua / .darkAqua`（对应 system/light/dark）。启动时 init 里调一次；无 GUI 进程下赋值是惰性 no-op，不崩。
  - NSColor 解析（仅此层碰 AppKit）：
    - `var accentColor: NSColor` — 由 `theme.accent` 的 RGBA 构造。
    - `func nameColor(for item: FileItem) -> NSColor` — `matchFileColorRule` 命中 → 规则色；未命中 → `.labelColor`。

### 视图层改读 ThemeStore（不再硬编码系统色）

- **`FileCellView.configure`**：
  - `marked` 行背景：`ThemeStore.shared.accentColor.withAlphaComponent(0.25)`（原 `controlAccentColor`）。
  - 名字文本色：`focus` → `.selectedControlTextColor`（保持高对比）；`marked`/normal → `ThemeStore.shared.nameColor(for: item)`。
  - `focus` 行背景仍用 `.selectedContentBackgroundColor`（系统色，保可读性）。
- **`PaneTableView.setActive`**：活动窗格边框用 `ThemeStore.shared.accentColor`（原 `.systemBlue`）。

## 三个维度的应用细节

- **外观**：改 segmented → `ThemeStore.update` → `applyAppearance()` 覆盖整个 app；因单元格用
  `labelColor`/`controlBackgroundColor` 等动态系统色，自动跟随。
- **强调色**：`NSColorWell` → `theme.accent`。驱动**标记行底色**（0.25 透明度）与**活动窗格边框**。
  焦点行保持系统 selection 色，避免浅强调色下焦点行不可读。
- **文件类型上色**：名字文本色按 `nameColor(for:)` 解析。应用于 **normal + marked** 行；**focus**
  行保留系统高对比文本。目录不上色。

## 出厂预置规则（可全量增删改）

| 分组 | 扩展名 | 颜色 |
|---|---|---|
| 文本/代码 | txt, md, log, swift, py, js, ts, json, xml, yml, yaml, sh, c, h, html, css, sql | 蓝灰 |
| 图片 | png, jpg, jpeg, gif, heic, webp, svg, bmp, tiff | 绿 |
| 视频 | mp4, mov, mkv, avi, webm | 紫 |
| 音频 | mp3, wav, flac, m4a, aac, ogg | 橙 |
| 压缩包 | zip, tar, gz, bz2, 7z, rar | 棕 |

其余文件 = 默认 `labelColor`。预置让装完即见效果；用户在主题窗里可改。

## 主题窗 UI

非模态窗（复用 `SearchWindowController`/`ConnectionWindowController` 的模式），单例由
`MainViewController` 持有（`let themeWindow = ThemeWindowController()`）。**改即生效**（无"确定"按钮，
每个控件的 action 直接 `ThemeStore.update`），减少状态管理。

`ThemeViewController` 布局（自上而下）：
1. **外观** — `NSSegmentedControl`（跟随系统 / 浅色 / 深色），`selectedSegment` 回读当前值。
2. **强调色** — `NSColorWell`，`color` 回读 `ThemeStore.shared.accentColor`。
3. **文件类型配色** — `NSScrollView` 包竖排 `NSStackView`；每行一个自绘行（`FileColorRuleRowView`
   = 扩展名 `NSTextField`（逗号分隔，如 `png, jpg`）+ `NSColorWell`）。**用自绘竖排列表而非
   `NSTableView`**（缩减 SDK 砍了 `registerClass:forIdentifier:`，表格坑多；规则数量短、自绘更稳）。
   底部"添加规则"/"删除选中"按钮。
4. **"恢复默认"按钮** — `ThemeStore.update(Theme.default)`。

**SDK 坑提醒**（写 AppKit 前必看 `project_reduced_sdk` memory）：程序化子视图一律
`translatesAutoresizingMaskIntoConstraints = false`；NSView 子类 `let` 存储属性用
隐式解包 `var ...!` 且 `super.init` 后再 wire delegate/action；`NSColorWell` 用
`isBordered`/`target+action`（点选即触发 action）。

## 入口（菜单 / 工具栏 / 命令栏）

- **菜单**：`MainMenu` 查看菜单加"主题…" → `MainViewController.menuTheme(_:)`。
- **工具栏**：`MainWindowController` 加 `theme` item（symbol 用 `paintpalette`），放 `.connect` 之后。
- **命令栏**：`InternalCommandExecutor` 加 `theme` 命令（无参数，弹主题窗）+ `helpText` 加一行；
  注入 `onOpenTheme` 钩子（仿 `onConnectSFTP`），`MainViewController` 接到 `menuTheme`。

## 测试

**TCCore — `ThemeTests`**（纯函数，快）：
- `fileExtension`：`.gitignore`→nil、`a.TAR.gz`→`gz`、`readme`→nil、`a.`→nil、`a.txt`→`txt`。
- `matchFileColorRule`：命中/大小写不敏感/多扩展名/未命中→nil/目录→nil/首条优先。
- `Theme` `Codable` round-trip；`Theme.default` 非空且规则合法（扩展名均小写无点）。

**FlyCommander — `ThemeStoreTests`**（注入 `UserDefaults(suiteName:)` 独立 suite）：
- 持久化 round-trip：`update` 后新 `ThemeStore(同 suite)` 读回一致。
- 无存储时回落到 `Theme.default`。
- `accentColor` / `nameColor(for:)` 映射正确（命中→规则色、未命中→labelColor）。

**XCUITest — 加 2~3 条**（需辅助功能授权，尽力而为）：
- 主题窗可打开（菜单"主题…"）。
- 外观切到"浅色"后重启 app 仍为浅色（跨重启持久化）。
- 加一条文件类型规则后重启仍保留。

主验证靠 SPM（`swift test`）+ 手动 `swift run FlyCommander` 目测三个维度；XCUITest 兜底。

## 文件清单

新增：
- `Sources/TCCore/Theme/Theme.swift`
- `Sources/FlyCommander/Theme/ThemeStore.swift`
- `Sources/FlyCommander/Theme/ThemeWindowController.swift`
- `Sources/FlyCommander/Theme/ThemeViewController.swift`（含自绘规则行 `FileColorRuleRowView`）
- `Tests/TCCoreTests/ThemeTests.swift`
- `Tests/FlyCommanderTests/ThemeStoreTests.swift`

修改：
- `Sources/FlyCommander/Panes/FileCellView.swift` — 读 ThemeStore（标记底/名字色）
- `Sources/FlyCommander/Panes/PaneTableView.swift` — `setActive` 边框用 accent
- `Sources/FlyCommander/App/MainViewController.swift` — 持有 `themeWindow`、订阅 `didChange` 刷新、`menuTheme`
- `Sources/FlyCommander/App/MainMenu.swift` — 查看菜单加"主题…"
- `Sources/FlyCommander/App/MainWindowController.swift` — 工具栏加"主题"
- `Sources/FlyCommander/Command/InternalCommandExecutor.swift` — `theme` 命令 + `onOpenTheme` 钩子 + helpText
- `Tests/FlyCommanderTests/InternalCommandExecutorTests.swift` — 加 `theme` 命令断言
- `UITests/FlyCommanderUITests.swift` — 加主题 XCUITest

`project.yml` 不改（无新 target）。

## 明确不做（本子周期范围外）

- 行密度 / 行高调整。
- 焦点行文本色不做主题化（保持系统高对比色）。
- 目录不上色。
- 多套主题切换（只有"当前主题"一份，可"恢复默认"）。
- 文件类型上色的分类算法不引入额外依赖——纯扩展名白名单匹配。
