# FlyCommander 多语言 Plan B 设计（OperationState / TCError 通道键化）

**日期：** 2026-09-02
**前置：** Plan A（AppKit 层文案外置，默认英文）已上 main（`2197dce`）。本 spec 覆盖 Plan A 明确搁置的最后一块中文残留：**经 `OperationState` 通道与 `TCError.message` 流出的文案**。
**决策来源（用户 2026-09-02 拍板）：** ① OperationState **结构 key 化**；② TCError **英文内部 + 边界翻译**。

## 目标（段 2）

让状态栏操作标签（重命名 / 新建目录 / 复制 N 个文件 / … 完成 / 源端残留警告）和错误正文（TCError 展开、系统错误映射）**随语言即时双语**，与 Plan A 已迁的直接显示串共用同一套 `L10nKey` + en/zh 表 + `t()`。终态：**全应用零硬编码用户可见中文**（注释除外）。

## 非目标

- 不改文件操作逻辑、不改进度/取消语义、不改传输算法。
- 不新增语言（仍 en/zh）。
- 不动 Plan A 已完成的直接显示路径。

## 现状与问题

TCCore 是零 AppKit 内核，不能持 `L10n`（那在 FlyCommander 层）。当前内核**直接产中文字符串**塞进两条通道，越过 AppKit 边界显示，故 Plan A 无法外置：

**通道 A — OperationState（`Sources/TCCore/Focus/Workspace.swift:3`）**
```swift
public enum OperationState: Equatable {
    case idle
    case running(label: String, progress: Double)   // label = 内核产中文
    case done(String)                              // 整句中文，如 "复制 3 个文件 完成"
    case failed(String)                            // = TCError.message
}
```
产点：`CommandRouter`（重命名/新建目录/本地传输 label + done/failed）、`TransferEngine:49/76`（`("复制"|"移动") + " N 个文件"` + done 句）、`SearchViewController`（`.done("搜索完成…")`/`.running(label:"搜索")`）。
消费：`MainViewController:285-288` `setStatus(label + pct)` / `setStatus(m)` / `setStatus(prefix + m)`。

**通道 B — TCError（`Sources/TCCore/TCError.swift`，6 case）**
`message` 直接返回中文模板串（"找不到：X"/"已取消"/…），payload 参数本身也常是内核内嵌中文（`OperationEngine:78 "已存在同名：X"`、`:113 "跨源传输暂不支持目录：X"`；`SMBSource "路径逃逸挂载点：X"`；`SMBMountManager "SMB 挂载失败…"`；`asTCError` 把 `NSFileWriteFileExistsError→unknown("目标已存在同名文件")`、`OutOfSpace→unknown("磁盘空间不足")`）。

**根因**：`unknown(String)`/各 case payload 是自由文本袋，内核往里塞中文，显示层只能原样打印。

## 设计

### 1. OperationState 结构 key 化（决策①）

改为**只携带 `L10nKey` + 结构化数据**，文案组装全移 AppKit 边界：
```swift
public enum OperationState: Equatable {
    case idle
    case running(label: L10nKey, progress: Double)      // key，非 String
    case done(label: L10nKey, note: String?)            // "X 完成" 的 X 键 + 可选后缀（如"（源端残留）"另为键）
    case failed(message: String)                        // 见下 §2：message 已是**当前语言成品串**
}
```
- **`label` 参数 = `L10nKey`**：编译期保证不再有散装中文穿通道（漏迁=编译不过，非静默）。新增键：`opRename`("Rename"/"重命名")、`opMkdir`("New Folder"/"新建目录")、`opCopying`("Copying {0} files"/"复制 {0} 个文件")、`opMoving`("Moving {0} files"/"移动 {0} 个文件")、`opDoneSuffix`（组装用）。`running` 进度格式 `"\(label) \(pct)%"` 的组装移到 `MainViewController`：`setStatus(t(label) + " " + pct + "%")`（复用 Plan A 的 `{0}` 约定；英文无空格/CJK 视需要微调，统一走一个 `t(.statusRunning, t(label), "\(pct)")` 之类模板键，具体键名计划阶段定）。
- **`done`**：内核/AppKit 产点只发 `label` key + 可选 `note`；`MainViewController` 用 `t(opDone, t(labelKey))` 组装"X 完成"。
- **`failed`**：**保持 String**——因为 TCError 翻译发生在边界（§2），到 `.failed` 时已是当前语言成品串。避免把 L10nKey 与自由文本混进同一 enum 的两副面孔。

**边界翻译器放哪**：`OperationState` 的 `label: L10nKey` 由 `MainViewController`（FlyCommander 层，持 `L10n`）在 `operationState` 回调里 `t()` 组装。TCCore 只 import `L10nKey`（已在 TCCore，AppKit-free）——**内核零新增依赖**。

> **`TransferEngine` 的 "复制/移动" label**（:49）：它是 AppKit 层，直接发 `.running(label: .opCopying, ...)` + `{0}=count`。注意 `count` 插值——`running` 只有 `label` 一个 key、无插值槽。**裁决**：给 `running` 加 `count: Int?` 载荷，或复用 `done` 式 `args: [String]`。**选后者**：`running(label: L10nKey, args: [String], progress: Double)`、`done(label: L10nKey, args: [String], note: String?)`——统一用一个 `args` 承载插值，边界 `t(key, args:)` 展开。更通用、少特例。

### 2. TCError 英文内部 + 边界翻译（决策②）

`message` 语义拆分：
- **`message: String`** → 变**稳定英文**（日志 / 测试断言 / 跨模块可比对；本工具走 SFTP 远程排障，英文日志更通用）。例：`.notFound(p)` → `"Not found: \(p)"`。
- **新增 `displayString: String`**（仅 FlyCommander 层可见——用 `extension TCError` 写在 AppKit 侧，或 TCCore 里存 `l10nKey: L10nKey` + 参数、AppKit 侧算 displayString）。**选后者**：TCError 每个 case 携带**语义键 + 原始参数**，不再内嵌模板文本：

```swift
public enum TCError: Error, Equatable {
    case notFound(String)          // 参数=路径，非已组装句
    case permissionDenied(String)
    case busy(String)
    case invalidPath(String)
    case cancelled
    case unknown(TCErrorCode, String?)   // 关键改动：unknown 不再是自由文本袋
}
```
- **`unknown(String)` 是最大问题**（什么都往里装：`"已存在同名"`、`"磁盘空间不足"`、`"目标已存在同名文件"`、`"SMB 挂载失败…"`、`"跨源传输暂不支持目录"`…）。**拆**：`asTCError` 的系统错误映射与内核内嵌中文，各自归入**语义子情形**（enum `TCErrorCode` 或直接加 case：`.alreadyExists(String)`、`.noSpace`、`.crossSourceDir(String)`、`.smbMountFailed(code:Int, diag:String)`、`.pathEscaped(String)`…）。每 case → 一个 `L10nKey`。
- **`displayString` 计算在 AppKit 侧**：`extension TCError { var displayString: String { switch self { case .notFound(let p): return L10n.t(.errNotFound, p) … } } }`。TCCore 仍零 `L10n` 依赖（只有 FlyCommander 的 extension 引用 L10n）。内核保留 `message`（英文）供非 UI 消费者。
- **显示点全切**：`MainViewController:287 .failed(m)`、`:256 setStatus`、连接窗 `connectFailedPrefix + message` 等所有 `.message`→`.displayString`。

**`asTCError` 不再产中文**：`NSFileWriteFileExistsError → .alreadyExists`（无 payload 句）、`OutOfSpace → .noSpace`；`default → .unknown(.generic, ns.localizedDescription)`（系统 desc 保留透传，本就是英文 locale 串）。

### 3. 键表与语言切换

- 新增键全进 `L10nKey` + `L10nTable.en/.zh`，`zh` 值**逐字**搬自现中文模板（含全角冒号/括号）。`allCases` 双表覆盖回归锁（Plan A 已有）自动要求每个新键两表齐。
- 即时切换：错误正文是**弹出/显示瞬间现取** `displayString`，非缓存 → 天然随语言（下次显示即用新语言）。状态栏 `running/done` 每次回调 `t()` → 即时。**无需**为 Plan B 加 observe 重绘（残留的只是"已显示的旧状态行在下一次操作前不变"，与 Plan A 对话框同级，可接受）。

## 影响面（改动清单）

| 文件 | 改动 |
|---|---|
| `TCCore/Focus/Workspace.swift` | OperationState 契约改（label→key、done→key+args、failed→String）|
| `TCCore/TCError.swift` | case 拆分（拆 `unknown`）、`message`→英文、加语义键 |
| `TCCore/Commands/CommandRouter.swift` | 产点改发 key+args（6 处）|
| `TCCore/Operations/OperationEngine.swift` | `throw` 改语义 case（4 处）、onWarning 键化 |
| `FlyCommander/Remote/{TransferEngine,SMBSource,SMBMountManager,SFTPClient}.swift` | 产点/映射键化 + `.message`→`.displayString` |
| `FlyCommander/App/MainViewController.swift` | 消费侧 `t()` 组装 + `.failed` 用 displayString |
| `FlyCommander/Search/SearchViewController.swift` | `.running`/`.done` 改 key |
| AppKit 侧 `TCError+Display.swift`（新建）| `displayString` extension |
| `L10nKey` + 两表 | 新增 ~15 键（状态标签 + 错误模板）|

**测试**：~30 处断言（内核 TCError.message 中文断言 + OperationState label/done 中文断言 + AppKit 消费）→ 英文默认值；`message` 英文断言（内部）+ `displayString` 中英双断（边界）。XCUITest：状态栏标签断言（如"复制…完成"）翻英，与 Plan A 的 `-appLanguage en` 一致。

## 边界判定（什么仍中文=正确）

无。Plan B 之后**不再有预期中文残留**（注释除外）。这是与 Plan A 的分水岭——Plan A 交付后状态栏/错误正文仍中文是**已知缺口**，Plan B 关闭它。

## 风险 / carry-forward

- **`OperationState` 是 `Equatable`**（有测试依赖等值比较）：改成含 `[String]`/`L10nKey` 后仍 Equatable（都 Equatable），不破。但 `TransferEngineTests` 里若按 `.running(label:"复制…")` 断言，需同步改 `label: .opCopying, args:["3"]`。
- **`unknown` 拆分是主要工作量与风险点**：11 处内嵌中文分派到语义 case，个别（`SMBMountManager` 带 exit code + 诊断前缀 200 字符）天然半结构化 → case 带 `code:Int, diag:String`，模板键 `{0}`/`{1}` 展开。诊断正文本身（非模板）仍 locale 透传。
- 手动冒烟：切语言→触发删除确认/冲突/传输→状态栏与错误正文随语言。
