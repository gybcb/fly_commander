# FlyCommander 窗格内文件筛选（Pane Filter）设计

**日期：** 2026-09-09
**分支：** `feat/pane-filter`（BASE `7adf5d5`）
**实现 commits：** `573484c` + `b66d50b`（Task 1 内核）/ `0c9b54a`（Task 2 视图投影）/
`b111156` + `934cd60` + `29dc1e7` + `c8b6bcd`（Task 3 筛选行 UI 与入口）/ `237c371`（Task 4 XCUITest）
**决策来源：** 用户 2026-09-08 拍板的五项决策（下 §1），实现期间经评审裁定 R1–R13 逐条落地。

## 目标

大目录里找文件靠眼睛扫。需求：**窗格上方一个筛选按钮，点开后输入筛选字符，下方列表实时只显示匹配项**。

```
┌────────────────────────────────┐
│ [tab1] [tab2]  + ×        🔍  │ ← 标签条 28pt（🔍 常驻，不在可滚动 stack 内）
│ 🔍 [ pdf            ] 清空  3/12 │ ← 筛选行 28pt（点 🔍 后展开）
├────────────────────────────────┤
│ 📁 docs/                       │
│ 📄 report.pdf                  │
│ 📄 notes.pdf                   │
└────────────────────────────────┘
```

## 非目标

- 不做递归筛选（那是 `FileSearcher` 的搜索功能，两者正交）。
- 不做多模式/正则输入（用户只批准「子串 + `*`/`?` 通配符」）。
- 不改 `SelectionModel` 的既有语义（`selectAll`/`.range`/`reload` 一律不动，见 §3）。
- 不改远端传输/命令行的其他路径。

## 1. 需求与五条决策

| # | 决策 | 落地位置 |
|---|---|---|
| 1 | **匹配方式**：默认不区分大小写**子串**；输入含 `*`/`?` 时切换为**通配符**（全串锚定，如 `*.pdf`、`report?.txt`） | `Sources/TCCore/Search/NameFilter.swift:19-39` |
| 2 | **目录也参与过滤**（不匹配的目录被隐藏） | 无特例分支：`recomputeVisibility()` 对 `page.items` 全量过滤（`Sources/TCCore/Focus/FilePane.swift:101-110`） |
| 3 | **仅当前目录生效**：导航（换目录）清空；同目录刷新（F5/操作后 reload）保留 | `navigate`/`setSource` 调 `clearFilter()`；`load`/`loadAsync` 只重算不清理（`Sources/TCCore/Focus/FilePane.swift:236-276`） |
| 4 | **形态**：标签条右端常驻按钮 → 展开 28pt 筛选行（输入框 + 清空 + 计数）；Esc 清空并回列表焦点，回车保留筛选并回列表焦点 | `Sources/FlyCommander/Panes/TabBarView.swift:23-67`、`Sources/FlyCommander/Panes/PaneTableView.swift:88-171`、`Sources/FlyCommander/Panes/PaneTableView.swift:261-301` |
| 5 | **操作范围**：筛选期 F5/F6/F8/全选/右键菜单/命令行 `del *` 只对**可见项**生效；被筛掉的标记视为未标记，**清空筛选也不恢复** | `FilePane.operationTargets/focusedItem` 门禁 + `restrictMarks` 破坏性剪枝（`Sources/TCCore/Focus/FilePane.swift:52-66`、`Sources/TCCore/Focus/FilePane.swift:117-124`） |

匹配语义的实现细节（`NameFilter`）：

- 空串 → `Kind.empty`，`matches` 恒真，`isEmpty == true`（无筛选态）。
- 含 `*` 或 `?` → `Kind.wildcard(NamePattern(text, caseSensitive: false))`，**全串锚定**（`^…$`）。
- 否则 → `Kind.substring`，走 `name.range(of: text, options: [.caseInsensitive])`，**不走正则**——`.`/`+` 等元字符按字面匹配。
- 输入**不 trim**：空白按字面匹配，只命中名字含空格的项（明确取舍，`NameFilterTests.testWhitespaceIsLiteralNotTrimmed` 锁定）。

## 2. 三条不变量

筛选激活时恒成立，全部由 `FilePane` 强制（视图不参与）：

| 不变量 | 实现 | 保证点 |
|---|---|---|
| **标记 ⊆ 可见** | `selection.restrictMarks(to: visibleIDSet)` —— 交集的**破坏性剪枝**，清空筛选不恢复 | `Sources/TCCore/Focus/FilePane.swift:119` |
| **焦点可见** | 焦点被筛掉 → 移到最近可见项；可见集为空时焦点无处可去（`focusIndex` 是非可选 `Int`） | `Sources/TCCore/Focus/FilePane.swift:120-123`、`Sources/TCCore/Focus/FilePane.swift:129-143` |
| **操作目标 ⊆ 可见** | 上一条 + `operationTargets`/`focusedItem` 的可见门禁共同保证 | `Sources/TCCore/Focus/FilePane.swift:52-66` |

收口点是 `enforceVisibleInvariants()`（`Sources/TCCore/Focus/FilePane.swift:117-124`），由两处调用覆盖：

- **结构性变化**：`load`/`loadAsync` 的成功与失败分支（`Sources/TCCore/Focus/FilePane.swift:168/173/178/221/226`）在 `selection.reload` 之后收口。
- **选择态变化**：`mutateSelection`（`Sources/TCCore/Focus/FilePane.swift:293-298`）在 `mutate` 之后收口。这一处即让 `selectAll()`（标全量）、`.range`（按存储索引跨过隐藏项）、`toggleMark`、`moveFocus` **全部自动满足**不变量，无需逐个改调用方。

**焦点落点取「最近可见」而非「首个可见」**（`nearestVisibleIndex`，`Sources/TCCore/Focus/FilePane.swift:129-143`）：从旧索引向**后**（索引递减，含自身）找，找不到再向**前**（递增）。动机是 `CommandRouter` 的 `.end` 走 `moveFocus(to: itemCount - 1)`（全量末索引），筛选下应落到**最后一个可见项**而不是第一个。

已披露的取舍：`revealItem(id:)` 目标被筛掉时仍返回 `true`（id 确实在 `items` 里），但焦点被收口到最近可见项——**「焦点可见优先」是有意为之，不是缺陷**（`FilePaneFilterTests.testRevealFilteredOutItemKeepsFocusVisible`）。

空可见集下：`operationTargets == []`、`focusedItem == nil`、`selectAll` 标空、`visibleCount == 0`；`itemCount` 仍是 `ls` 报的目录**总数**（不受筛选影响）。

## 3. 内核 / 视图分工

### 3.1 筛选状态住 `FilePane`，不住视图

决定性理由：决策 3 的「导航清空 / 刷新保留」分界**只在内核存在**——`FilePane.navigate`/`setSource` 与 `FilePane.load` 是两条不同入口（`load` 被导航、操作后 reload、F5 共用），视图层看不到这个区别，只能靠比对 path 字符串猜。放内核则「清空」由构造保证，且语义可用最便宜的 TCCore 单测穷举。

`FilePane` 的筛选状态：

```swift
public private(set) var filterText = ""   // 视图筛选行每键击经 setFilter 写入
private var filter: NameFilter?
private var visibleIDs: [String]?         // 可见项 id，存储序（= page.items 顺序）；nil = 无筛选
private var visibleIDSet: Set<String>?    // 可见性门禁用集合；nil = 无筛选（门禁默认放行）
```

派生 API：`isFiltering`、`visibleItemIDs`（**存储序**，视图自行排序）、`visibleCount`、`itemCount`（全量）。

### 3.2 视图只做投影

`PaneTableView.displayIDs` 是显示顺序的 item id 列表，由 `pane.visibleItemIDs` 经视图层排序派生（`Sources/FlyCommander/Panes/PaneTableView.swift:181-196`）：

```swift
displayIDs = PaneTableView.sortedIDs(pane.visibleItemIDs, items: pane.itemByID,
                                     key: sortKey, direction: sortDirection)
```

无筛选时 `visibleItemIDs == page.items.map(\.id)`，逐位等价旧行为；筛选态下即「可见 ∩ 已排序」。**排序仍完全留在视图层**——`visibleItemIDs` 返回存储序，视图叠自己的排序，两者互不污染（`PaneTableViewFilterTests.testFilterComposesWithSort`）。

空可见集时 `navigate(delta:)`/`navigate(toEdge:)` 首行 `guard !displayIDs.isEmpty else { return }`（`Sources/FlyCommander/Panes/PaneTableView.swift:591-609`）：否则 `targetSelectionIndex` 空表返回 0，焦点会落到被筛掉的 `items[0]`（隐藏项）。

### 3.3「只对可见项生效」的收口

`operationTargets`/`focusedItem`/`selectAll`/`.range` 有十余个消费点（`CommandRouter`、`MainViewController`、`InternalCommandExecutor`、`TransferEngine`），视图层最多拦住 `PaneTableView.keyDown` 一条。故**不变量由 `FilePane` 强制**：

- 可见门禁：`guard visibleIDSet?.contains(id) ?? true else { return nil }`（`Sources/TCCore/Focus/FilePane.swift:56`、`Sources/TCCore/Focus/FilePane.swift:63`）。`?? true` 使**无筛选时逐位等价旧行为**。
- `mutateSelection` 是选择态变更的**单一收敛点**（`Sources/TCCore/Focus/FilePane.swift:293-298`），`selectAll`/`.range`/`toggleMark`/`moveFocus` 全走它。
- `SelectionModel` 只加一个最小写入口 `restrictMarks(to:)`（`Sources/TCCore/Selection/SelectionModel.swift:93-95`），`items`/`focusIndex`/`anchor` 一律不动——可见性概念留在 `FilePane` 侧。
- 命令行 `del *` 是唯一绕过 `operationTargets` 的删除路径，单独收口（`Sources/FlyCommander/Command/InternalCommandExecutor.swift:183-187`）。

状态栏计数也改走可见感知：`updateBars()` 由 `a.selection.operationIDs.count` 改 `a.operationTargets.count`（`Sources/FlyCommander/App/MainViewController.swift:430-437`）——空可见集时 `operationIDs` 会回退成 `[focusID]`，用它状态栏会谎报「已选 1 项」。

## 4. 可见集失效策略

**`page` 的 `didSet` 是唯一的结构性失效点**（`Sources/TCCore/Focus/FilePane.swift:12-14`）：

```swift
public private(set) var page: DirectoryPage? {
    didSet { recomputeVisibility() }
}
```

`page` 的每次赋值——`load`/`loadAsync` 的**成功与失败**分支、`setSource` 的 `page = nil`——都经 `didSet` 重算缓存，结构上不可能陈旧。这是 R1 的裁定：计划原定在 `load` 各分支显式调 `recomputeVisibility()`，评审的对抗式批判指出「列 6 个调用点」必然漏掉失败分支。

`recomputeVisibility()`（`Sources/TCCore/Focus/FilePane.swift:101-110`）是可见集的**唯一写入口**，且**从 `page.items` 派生，不读 `selection.items`**——`load()` 里 `page =` 早于 `selection.reload`，读 selection 会拿到旧值。无筛选（`filterText` 空）→ 两个缓存置 nil，门禁默认放行。

`setFilter`（`Sources/TCCore/Focus/FilePane.swift:81-89`）与 `clearFilter`（`Sources/TCCore/Focus/FilePane.swift:92-97`）因 `filterText` 变化显式调用 `recomputeVisibility()`。`setFilter` 的语义：

- 文本无变化 → 直接返回（不重算、不发回调）。
- 文本变化 → 重算可见集 → `enforceVisibleInvariants()` → 与 `mutateSelection` 同款 before/after diff，**仅选择态真变时**发 `onSelectionChange`（含「只剪标记、焦点原地」的情形，Task 3 的 `updateBars` 依赖此契约）。
- **绝不发 `onReload`**：那会每键击重建标签条（`MainViewController.refresh` → `container.show`）+ 走会话写回（`recordSessionIfChanged`）。**省不掉** `sortedIDs` 重排——视图侧 `reload()` 无论如何都要重投影一次。

## 5. 性能

| 关注点 | 做法 | 理由 |
|---|---|---|
| 每键击逐项匹配 | `NamePattern` **构造时预编译** `private let compiled: NSRegularExpression?`，`matches` 复用 | 旧实现每次 `matches` 都重编正则，2 万项/键击不可接受；改动同时加速既有 `FileSearcher`（`Sources/TCCore/Search/FileSearcher.swift:10-40`） |
| 子串匹配 | `range(of:options:.caseInsensitive)`，**零正则** | 元字符按字面；无编译开销 |
| 每键击渲染 | `setFilter` 不发 `onReload`，视图自行 `reload()` 重投影 | 避免每键击重建标签条 + 会话写回（`sortedIDs` 重排省不掉，`reload()` 必跑） |
| 选择态刷新 | 既有 `refreshSelection()` 快路（只重建可见行 + 同步滚动） | `setFilter` 发的 `onSelectionChange` 在**旧** `displayIDs` 上做一次廉价刷新，紧随其后的 `reload()` 是权威刷新（R5 已裁定，无崩溃路径） |
| 计数标签 | 宽度用 `greaterThanOrEqualToConstant(56)` 而非定宽 | 大目录 `12345/67890` 不该被压成省略号（本特性主场景） |

`NameFilterTests` 逐条锁定匹配语义（空模式、大小写、包含而非全等、元字符字面、`*`/`?` 锚定、不 trim），每条带变异说明。

## 6. 已知取舍

1. **命令行显式 `del <id>` 在筛选期仍可命中隐藏项。** `del *` 已收窄到 `pane.visibleItemIDs`（`Sources/FlyCommander/Command/InternalCommandExecutor.swift:183-187`），但显式命名分支**故意不动**（`Sources/FlyCommander/Command/InternalCommandExecutor.swift:188-196`）：用户逐字敲出名字是明确意图，加白名单会把「按名删除」变成「按名删除但可能被静默忽略」。R4 已裁定保持此取舍（`testDelExplicitIDIgnoresFilter` 锁定）。
2. **远端异步导航下，内核清空筛选先于筛选行输入框的文本同步。** `FilePane.navigate` 远端分支在回主线程改 path 时 `clearFilter()`，而 `PaneTableView` 的输入框同步发生在随后的 `reload()` 里（`Sources/FlyCommander/Panes/PaneTableView.swift:184-186` 的 `filterText.isEmpty` 分支回写 `stringValue`）。滞后的是**输入框文本**，筛选行本身保持展开（可见性只由 `setFilterRowVisible` 改），两者之间有可接受的滞后窗口。
3. **未做输入去抖。** 每键击一次全量投影。若大目录实测卡顿，可在 `controlTextDidChange` 加 ~100ms 去抖——纯视图层改动，内核无感（`NameFilter` 预编译已把匹配本身压到 O(1)/项）。
4. **筛选行可见性的滞后**：非活动标签的筛选行状态变化不驱动标签条按钮（`Sources/FlyCommander/Panes/SidePaneContainer.swift:53-56` 只在 `pv === activePaneView` 时回写），切标签时由 `show()` 重算（`Sources/FlyCommander/Panes/SidePaneContainer.swift:94`）。
5. **`del *` 的语义边界**：`del *` 删可见项、`del`（无参）删 `operationTargets`（标记 ∪ 焦点，均已可见）。两者在筛选期都只作用于可见集。

## 7. 测试策略

三层，每层只测它能真证伪的东西；**每条新测试的注释写明变异**（改哪一行会让它转红）。

| 层 | 文件 | 覆盖 | 数量 |
|---|---|---|---|
| TCCore 内核 | `Tests/TCCoreTests/NameFilterTests.swift` | 匹配语义（空/大小写/子串/元字符/通配符锚定/不 trim） | 9 |
| TCCore 内核 | `Tests/TCCoreTests/FilePaneFilterTests.swift` | 三不变量、空可见集门禁、标记剪枝不恢复、`.range` 跨隐藏项、焦点落点、导航清空/刷新保留/切源清空、加载失败不残留、`loadAsync` 两分支 | 19 |
| TCCore 内核 | `Tests/TCCoreTests/SelectionModelTests.swift` | `restrictMarks` 交集（变异：`formIntersection` → `formUnion`） | +1 |
| AppKit headless | `Tests/FlyCommanderTests/PaneTableViewFilterTests.swift` | 投影取 `visibleItemIDs`、与排序叠加、空命中导航 no-op ×2、清空复原、无筛选回归 | 6 |
| AppKit headless | `Tests/FlyCommanderTests/FilterBarWiringTests.swift` | 默认收起、展开/收起、约束卫生、键入过滤 + 计数、语言切换重刷、常驻按钮存活 `rebuild` + 回调、`updateBars` 可见感知、标签条 → 活动窗格接线、⌘⇧F 菜单项、**真实响应者链 ⌃⇥ 方向**、Esc 收口回写、计数宽度下限 | 12 |
| AppKit headless | `Tests/FlyCommanderTests/InternalCommandExecutorTests.swift` | `del *` 只删可见项、显式 `del <id>` 忽略筛选 | +2 |
| AppKit headless | `Tests/FlyCommanderTests/PaneSortTests.swift` | `sortedIDs` 跳过缺失 id（第二道防线，杜绝缓存陈旧崩溃） | +2 |
| XCUITest（真窗） | `UITests/PaneFilterUITests.swift` | 🔍 展开、子串收窄左表（右表不动）、计数 `可见/总数`、Esc 复原、⌘⇧F 入口、清空按钮保持展开、通配符 `*.txt` 全串锚定 | 7 |

分工原则：SPM 覆盖内核与 headless 视图（快、可穷举），XCUITest 只验证**真实 AX 树**下 SPM 测不到的事实（AX 可达性、真键盘事件、真窗布局）。三条真实 AX 事实已 dump 实证并写进类注释：行名 = 行内 x 最小 StaticText 的 `value`；收起时筛选行**不在 AX 树**；`paneFilterButton` 的开关态 AX 不可读（`momentaryPushIn` 不暴露 `AXValue`）——故按钮态同步由 Tier 1 覆盖，UI 层改以「⌘⇧F 展开后点 🔍 应收起」佐证同一入口。

## 8. ⌃⇥ 响应者链的坑（最反直觉的一条）

**症状**：筛选输入框聚焦时按 ⌃⇥ 不切标签（而 `PaneTableView` 里的 ⌃⇥ 是 TC 式切标签）。

**根因链**（探针实证，2026-09-09）：

1. `makeFirstResponder(filterInput)` 后，`window.firstResponder` **不是输入框自身**，而是 **field editor（`NSTextView`）**；输入框是它的 `delegate`。因此**覆写 `FilterInputField.keyDown` 收不到 ⌃⇥**——那是死代码。（计划 §2 原定「输入框覆写 `keyDown` 转交」的方案由此被证伪并推翻，本文档不将其视为设计。）
2. macOS 把 ⌃⇥/⌃⇧⇥ 占作原生 window tabbing，在 `NSWindow.sendEvent` 层、`firstResponder.keyDown` 之前拦截；`tabbingMode = .disallowed` 与 `NSAllowsAutomaticWindowTabbing = false` 在本 SDK（Xcode 26.6 / macOS 26）下**拦不住**该 key binding（已 probe 实证）。故 `FlyWindow.sendEvent` 必须手动抢在 `super.sendEvent` 之前处理。
3. field editor 把 ⌃⇥ 与 ⌃⇧⇥ **都**映射成同一个 `selectNextKeyView:`（无方向信息），所以走 `doCommandBy` 只能靠 `NSApp.currentEvent` 猜方向——而测试直调 `win.sendEvent(event)` 时 `NSApp.currentEvent` 为 **nil**。

**现方案**（R8）：

```swift
// Sources/FlyCommander/App/MainWindowController.swift:18-21
protocol ControlTabRouting: NSResponder {
    func handleControlTab(shift: Bool) -> Bool   // 返回 true = 已消费
}

// FlyWindow.sendEvent 的 ⌃⇥ 分支（Sources/FlyCommander/App/MainWindowController.swift:34-48）
if let routed = (firstResponder as? NSTextView)?.delegate as? ControlTabRouting,
   routed.handleControlTab(shift: event.modifierFlags.contains(.shift)) {
    return
}
firstResponder?.keyDown(with: event)   // 非输入框路径：PaneTableView 处理 .nextTab/.prevTab
return                                  // 消费掉，不交给 super
```

- **解到 field editor 的 `delegate` 再投递**：`FilterInputField` 实现 `ControlTabRouting`（`Sources/FlyCommander/Panes/PaneTableView.swift:743-755`），`handleControlTab` 转发到 `onControlTab` 闭包。
- **方向从 event 本体取**（`event.modifierFlags.contains(.shift)`），**不用 `NSApp.currentEvent`**。方向语义与 `KeyDispatcher` 的既有约定一致：⌃⇧⇥ = 上一标签（`shift ? .prevTab : .nextTab`，R6）。
- **opt-in 协议**把影响面限制在显式声明的输入框：未实现协议的 firstResponder（如命令行输入框）走原 `firstResponder?.keyDown` 路径，行为逐位不变（re-review 探针实证）。

**测试必须建真实 `FlyWindow` 并 ≥3 个标签**（`FilterBarWiringTests.testControlTabRoutesThroughRealResponderChainWithDirection`）：

- 真实窗口 + `makeFirstResponder(filterInput)` + `win.sendEvent(⌃⇥)`，用 `workspace.leftTabs.activeIndex` 断两个方向。
- **≥3 个标签是必要条件**：2 个标签时 ⌃⇥ 按两次会 wrap 回 0，「方向写死 `.nextTab`」的变异会**假绿**。R9 原写「2 个标签」，实现方用 3 个并说明理由，复审判定「接受，且是『变异必红』自洽的必要条件」。
- 测试首行显式断言 `win.firstResponder is NSTextView`，否则失败原因会被误读为接线错误。

## 9. 计划与实现的出入（以代码为准）

| # | 计划原定 | 实际落地 | 原因 |
|---|---|---|---|
| 1 | `load`/`loadAsync` 各分支显式调 `recomputeVisibility()` | `page.didSet` 单一失效点自动重算（R1） | 「列 6 个调用点」必然漏掉失败分支 |
| 2 | `recomputeVisibility` 按 `selection.items` 存储序遍历 | 从 `page.items` 派生 | `load()` 里 `page =` 早于 `selection.reload`，读 selection 会拿到旧值 |
| 3 | 输入框覆写 `keyDown` 转交 ⌃⇥ | `ControlTabRouting` 协议 + `FlyWindow.sendEvent` 解 delegate 投递（R8） | field editor 使覆写成为死代码（§8） |
| 4 | ⌃⇥ 方向未明确 | `shift ? .prevTab : .nextTab`（R6） | 与 `KeyDispatcher` 既有约定一致 |
| 5 | 按钮点击后 `syncFilterButton()` 显式同步 | `PaneTableView.onFilterRowVisibilityChange` 单一收口 + `SidePaneContainer.addTab` 回写（R7） | Esc 收起行同样不同步（用户更常走），显式同步只堵一半 |
| 6 | 计数标签定宽 56pt | `>= 56`（R10） | 大目录是本特性主场景 |
| 7 | `sortedIDs` 用 `items[id]!` | 跳过缺失 id（R2） | 第二道防线，杜绝缓存陈旧导致崩溃 |
| 8 | 清空按钮标题 `✕` / `filterClearTip` | `L10n.t(.filterClearTip)`（"Clear"/"清空"）（R3） | 避免与标签条关闭按钮的 `×` 在 AX 树撞车，污染既有 XCUITest |
| 9 | ⌃⇥ 测试 2 个标签 | 3 个标签 | 2 个标签时 wrap 假绿 |

## 10. 代码索引

| 关注点 | 位置 |
|---|---|
| 匹配器 | `Sources/TCCore/Search/NameFilter.swift` |
| 通配符预编译 | `Sources/TCCore/Search/FileSearcher.swift:10-40`（`NamePattern`） |
| 标记写入口 | `Sources/TCCore/Selection/SelectionModel.swift:93-95`（`restrictMarks`） |
| 筛选状态 + 三不变量 | `Sources/TCCore/Focus/FilePane.swift:18-143` |
| 可见集失效点 | `Sources/TCCore/Focus/FilePane.swift:12-14`（`page.didSet`） |
| 可见门禁 | `Sources/TCCore/Focus/FilePane.swift:52-66`（`operationTargets`/`focusedItem`） |
| 选择态收敛点 | `Sources/TCCore/Focus/FilePane.swift:293-298`（`mutateSelection`） |
| 导航清空 / 刷新保留 | `Sources/TCCore/Focus/FilePane.swift:236-276` |
| `del *` 收口 | `Sources/FlyCommander/Command/InternalCommandExecutor.swift:179-201` |
| 状态栏可见感知 | `Sources/FlyCommander/App/MainViewController.swift:430-437` |
| ⌘⇧F 菜单入口 | `Sources/FlyCommander/App/MainMenu.swift:55`、`Sources/FlyCommander/App/MainViewController.swift:475-477` |
| 常驻 🔍 按钮 | `Sources/FlyCommander/Panes/TabBarView.swift:23-67` |
| 容器接线 / 按钮态回写 | `Sources/FlyCommander/Panes/SidePaneContainer.swift:32`、`Sources/FlyCommander/Panes/SidePaneContainer.swift:53-56`、`Sources/FlyCommander/Panes/SidePaneContainer.swift:99-102` |
| 筛选行 UI | `Sources/FlyCommander/Panes/PaneTableView.swift:88-171` |
| 视图投影 | `Sources/FlyCommander/Panes/PaneTableView.swift:181-196`（`reload`） |
| 展开/收起 + 唯一收口 | `Sources/FlyCommander/Panes/PaneTableView.swift:261-275` |
| 输入/清空/回车/Esc | `Sources/FlyCommander/Panes/PaneTableView.swift:278-301` |
| ⌃⇥ 协议与投递 | `Sources/FlyCommander/App/MainWindowController.swift:18-48`、`Sources/FlyCommander/Panes/PaneTableView.swift:743-755` |
| L10n 键 | `Sources/TCCore/L10n/L10nKey.swift:84-85`、`Sources/TCCore/L10n/L10nStrings.swift:139-140/279-280` |
