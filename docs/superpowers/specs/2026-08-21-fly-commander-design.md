# FlyCommander 设计文档

> 在 macOS 上用 Swift (AppKit) 复刻 Total Commander（TC）——键盘优先、双窗格、密集多列的经典文件管理器。

- **文档日期**：2026-08-21
- **状态**：已批准（经头脑风暴逐段确认）
- **范围**：尽量完整复刻 TC，分能力域 + 分期推进；每期独立「设计 → 计划 → 实现」，内核协议保证可插拔扩展
- **本次交付**：P0 骨架 + P1 核心文件管理（可用 MVP）

---

## 1. 目标与定位

复刻 Total Commander 的核心体验：双窗格并排浏览、F 键驱动的键盘操作、密集多列文件列表。不做成 Finder 的现代 GUI 风格，而是还原 TC 的键盘优先交互。

## 2. 关键决策

| 决策项 | 选择 | 理由 |
|---|---|---|
| 范围 | 尽量完整复刻（分期） | 用户诉求 |
| UI 框架 | AppKit | 贴合 TC 键盘密集、多列重交互；`NSCollectionView` 焦点/虚拟化控制力强于 SwiftUI `List` |
| 最低系统 | macOS 14 (Sonoma) | 覆盖广，可用最新大部分 API |
| 交互 | 键盘优先（F 键驱动），保留 `Cmd+` 补充 | TC 灵魂 |
| P1 范围 | 完整核心 | 浏览 + 复制/移动/删除/重命名/建目录 + 选择模型 + 状态栏/命令栏 |
| 分发 | 本地自用 | 无 App Sandbox、无签名，可自由访问路径、调用系统命令 |
| 架构 | 方案 C：headless 纯 Swift 内核 + 薄 AppKit 视图层 | 内核 100% 可单测；FTP/压缩/命令行只换内核实现，视图层几乎不动 |
| 内核→视图 | 闭包/delegate 回调 | 纯 Swift、最轻；内核不 import AppKit、不感知 UI |
| 双窗格焦点 | TC 经典（Ctrl+←/→、Tab；单击可激活非活动窗格） | TC 行为 |
| 文件列表控件 | NSCollectionView | 键盘焦点/虚拟化控制力 |
| 浏览模式 | P1 扁平浏览（不做子树展开） | TC 默认行为，最简单 |
| 冲突处理 | 逐文件弹窗（覆盖/跳过/全部覆盖/全部跳过） | TC 经典 |
| 删除 | F8 进废纸篓 | macOS 习惯，更安全、可恢复 |
| 项目组织 | 本地 SPM 单工程（`Packages/TCCore` + `Apps/FlyCommander`） | 代码与依赖清晰分离 |
| 命名 | 应用 FlyCommander，内核包 TCCore | 已确认 |

## 3. 能力域与分期（路线图）

| 期 | 内容 | 状态 |
|---|---|---|
| **P0 骨架** | SPM + 工程、主窗口、双窗格布局、键盘命令分发骨架 | 本次 |
| **P1 核心文件管理（MVP）** | 浏览 + 复制/移动/删除/重命名/建目录 + 选择模型 + 状态栏/命令栏 + 内核测试 | 本次 |
| P2 | 查看(F3)/编辑(F4) + 搜索（文件名/内容） | 后续 |
| P3 | 压缩/解压缩（zip / tar / 7z / rar） | 后续 |
| P4 | 命令行集成 + 远程（FTP/SMB/WebDAV，复用 `FileSource` 协议） | 后续 |
| P5 | 多标签 + 图标/列表/详情视图切换 + 目录热键 + 主题 | 后续 |

## 4. 架构（方案 C：内核 + 薄视图）

### 4.1 核心原则

内核 `TCCore` 是 headless 纯 Swift 包，**零 AppKit 依赖**，承载全部业务逻辑，100% 可单测。AppKit 层只做**渲染、焦点、事件转发**，通过闭包/delegate 回调刷新。后期叠 FTP/压缩/命令行只换内核的数据源/操作实现，视图层几乎不动。

单向数据流：**输入（键/点击）→ 内核 → 回调 → 视图**。视图不直接改内核状态，内核不 import AppKit。

### 4.2 内核 TCCore 模块

| 模块 | 职责 | 关键类型 |
|---|---|---|
| 路径层 | 统一路径模型（基于 `URL`/`FileManager`），处理隐藏文件、`~`、相对路径 | `TCPath`, `PathUtils` |
| 目录模型 | 某目录的一页内容：文件项、排序、过滤、分页 | `DirectoryPage`, `FileItem` |
| 选择模型 | 单选/Ctrl/Shift/空格或 Alt+Q 标记；区分「焦点项」与「已标记集合」 | `SelectionModel`, `MarkedSet` |
| 文件操作流水线 | 复制/移动/删除/重命名/建目录的编排（进度、冲突、可取消、回滚） | `FileOperation`, `OperationEngine`, `ConflictPolicy` |
| 命令系统 | 中央 `CommandMap`：键位/热键 → `Command`；窗格是命令接收者 | `Command`, `CommandContext`, `CommandMap` |
| 焦点/窗格模型 | 双窗格焦点状态、TC 经典切换 | `PaneState`, `FocusController` |
| 数据源抽象 | `FileSource` 协议——本地默认实现，FTP/SMB 后续新增实现 | `FileSource`, `LocalFileSource` |
| 事件 | 内核→视图 回调协议（`willPerform`/`didPerform`、状态变更） | `CoreEvents` |

### 4.3 AppKit 视图层（FlyCommander，薄）

- **主窗口** `MainWindowController`：双窗格 + 工具条 + 命令栏 + 状态栏，窗口本身不做业务
- **每个窗格** `PaneView`（`NSView`）：顶部标签/面包屑条（P1 单标签）+ 中部 `PaneTable`（`NSCollectionView`，三列：文件名/大小/修改时间）；把 `keyDown`/点击/滚轮全部转给内核，监听内核回调刷新
- **命令栏**（TC 底部输入行）：P1 只读状态显示（活动窗格路径 + 选中数），命令解析留给 P4
- **状态栏**：磁盘容量、选中项统计

### 4.4 键盘事件流（关键路径）

```
NSResponder.keyDown
  → PaneView 拦截 F 键 / 方向键 / Tab / 空格 / Ctrl+←→
  → 组装 CommandContext(activity=本窗格)
  → 内核 CommandMap 解析并执行
  → 内核回调 → PaneView 刷新
```

非活动窗格也能被**单击激活**（TC 行为），点击只改焦点、不触发双击。

## 5. 命令系统（TC 灵魂，P1 注册的核心命令）

| 键 | 命令 | 说明 |
|---|---|---|
| `↑/↓` `PgUp/PgDn` `Home/End` | 移动焦点项 | 扁平列表内移动焦点 |
| `→/Enter` | 进入目录 | 焦点在目录上时 |
| `←/Backspace` | 返回上级 | |
| `Ctrl+←/→`、`Tab` | 切换活动窗格 | TC 经典 |
| `F5` | 复制 | 复制到**非活动窗格**（TC 行为） |
| `F6` | 移动 | 同上 |
| `F7` | 新建目录 | 弹出输入框 |
| `F8` | 删除 | 弹确认框，进废纸篓 |
| `Delete` | 重命名 | P1 先做重命名 |
| `空格` / `Alt+Q` | 标记/取消标记焦点项 | TC 用 Alt+Q |
| `Ctrl+点击` / `Ctrl+↑↓` | 增选 | |
| `Shift+↑↓` | 范围选择 | |
| `Esc` | 取消选择/退出输入 | |
| `Cmd+←/→`、面包屑点击、`Cmd+C/V` | macOS 习惯补充 | 与 F 键等价，不冲突 |

**执行模型**：`CommandContext` = { 活动窗格, 焦点项, 标记集合, 目标窗格（对侧）, 路径 }。修改类命令走 `OperationEngine`：冲突检测（同名→逐文件弹窗）、进度（可取消）、完成回调刷新双窗格；执行前后发 `willPerform`/`didPerform`，状态栏/命令栏据此显示。

**有意保留的 macOS 习惯**：保留 `Cmd+` 系列作为等价补充；删除走**废纸篓**（`NSWorkspace.shared.recycle`）而非直接删除，更安全。

## 6. 数据流 / 错误处理 / 测试

- **单向数据流**：输入(键/点击) → 内核 → 回调 → 视图。
- **错误**：内核 I/O 用 `throws`，归一化为 `TCError`（无权限/不存在/被占用/被拒）。`OperationEngine` 失败时回滚部分完成的操作（如移动失败则移回）。视图层把 `TCError` 转成 `NSAlert`。macOS 隐私目录（~/Desktop、~/Documents）首次访问提示授权，P1 在 README 说明。
- **测试**（内核 100% 覆盖）：
  - 选择模型：单选/Ctrl/Shift/标记 全组合
  - 文件操作：临时目录真实文件系统测试（冲突、取消、回滚）
  - 命令系统：给定 `CommandContext` 验证解析与路由
  - 目录模型：排序/过滤/分页
  - 数据源：`LocalFileSource` 真实目录读取
  - AppKit 层：焦点切换、键位分发少量 UI 测试补

## 7. 项目结构

```
fly_commander/
├─ Packages/TCCore/               # headless 内核，纯 Swift
│   ├─ Package.swift
│   ├─ Sources/TCCore/
│   │   ├─ Path/                  # TCPath, PathUtils
│   │   ├─ Model/                 # DirectoryPage, FileItem
│   │   ├─ Selection/             # SelectionModel, MarkedSet
│   │   ├─ Commands/              # Command, CommandMap, CommandContext
│   │   ├─ Operations/            # FileOperation, OperationEngine, ConflictPolicy
│   │   ├─ Focus/                 # PaneState, FocusController
│   │   ├─ Sources/               # FileSource, LocalFileSource
│   │   └─ Events/                # 内核→视图 回调协议
│   └─ Tests/TCCoreTests/…
└─ Apps/FlyCommander/             # AppKit 薄视图层
    ├─ App/                       # AppDelegate, MainWindowController
    ├─ Panes/                     # PaneView, PaneTable(NSCollectionView), 面包屑
    ├─ Bars/                      # 命令栏, 状态栏
    └─ Support/                   # 键位分发、资源
```

## 8. 实施计划（P0 + P1）

> 用 TDD 推进。内核先写测试再实现；AppKit 层以可运行验证为主。详细步骤见 writing-plans 产出的实现计划。

### P0 骨架
1. 初始化 Xcode 工程（SPM）：`Packages/TCCore` 本地包 + `Apps/FlyCommander` App target（macOS 14+）
2. 内核骨架：`TCPath`/`PathUtils`、`FileItem`/`DirectoryPage`（空实现 + 测试）、`FileSource`/`LocalFileSource` 协议与本地实现
3. App 骨架：`AppDelegate`、`MainWindowController`（双窗格 NSView 占位 + 工具条/命令栏/状态栏占位）、键盘事件分发框架（`keyDown` → 内核）

### P1 核心文件管理
4. 选择模型 `SelectionModel`/`MarkedSet` + 全组合测试
5. `PaneTable`（`NSCollectionView`，三列：文件名/大小/修改时间）渲染 `DirectoryPage`；扁平浏览（进入/回退/上级）
6. 焦点模型 `PaneState`/`FocusController`：Ctrl+←/→、Tab、单击激活非活动窗格
7. 命令系统 `Command`/`CommandMap`/`CommandContext` + 路由测试；注册全部 P1 键位
8. 操作引擎 `OperationEngine`：复制/移动（冲突逐文件弹窗、进度可取消、完成刷新双窗格）；删除 F8 → 废纸篓 + 确认；重命名（`Delete`）输入框；新建目录 F7 输入框
9. 状态栏（磁盘容量、选中统计）+ 命令栏（活动路径、选中数、操作状态）
10. 内核全量测试跑通；App 手动验证

### P1 验证（端到端）
- `swift test` 全绿（TCCore 选择/命令/操作/目录/数据源）
- Xcode 运行 `FlyCommander`：双窗格正确列出文件/大小/时间；↑↓ 移动焦点、→ 进目录、← 回上级、Ctrl+←/→ 与 Tab 切换活动窗格、单击可激活非活动窗格；空格/Alt+Q 标记、Ctrl 增选、Shift 范围选择，状态栏选中数正确；F5 复制、F6 移动到对侧，同名逐文件弹窗生效、可取消、完成后双窗格刷新；F7 建目录、Delete 重命名、F8 删除进废纸篓（可恢复）；底部命令栏/状态栏实时反映路径、选中数、操作进度
- 授权场景：访问 ~/Desktop、~/Documents 触发 macOS 授权提示

## 9. 复用

无既有代码可复用（空项目）。实现时优先复用 macOS 原生能力：`FileManager`（目录读取/复制/移动/重命名）、`NSWorkspace.shared.recycle`（废纸篓）、`NSCollectionView`（列表）、`URLResourceValues`（元数据）、`NSOpenPanel`（授权/选路径）。

## 10. 假设与待决

- **假设**：P1 的「目录页」一次性加载整个目录（不虚拟化分页）——TC 也是整目录列出。若单目录文件量极大再考虑分页（已在目录模型预留分页接口）。
- **待决**：`Alt+Q` 与「空格」都作为标记切换，二者都注册（空格更符合 macOS，Alt+Q 贴合 TC）。
- **待决**：P1 命令栏是否允许用户输入 `..` 直接跳转上级——预留，默认只读。
