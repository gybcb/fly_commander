# 目录/批量拷贝的全进度显示 — 设计规格

**日期**：2026-10-08
**分支**：fix/same-server-copy-progress（复用；前一同服务器进度改动已完成未合并）
**状态**：待用户评审

## 1. 问题与目标

用户报障：**拷贝目录时面板只显示当前单文件的速度和进度，看不到整个目录的全进度。**

现状（代码核实）：

- 面板进度条百分比、字节数、速度、剩余时间全部来自帧的 `bytesDone/bytesTotal`
  （TransferProgressWindowController.swift:210-245），而该对值按引擎合同是
  **单文件内**进度（OperationEngine.swift:331-335，终审 B2 裁定）→ 拷大目录时
  条与速度永远反映「当前这个文件」，整体进度只看得到标题里的 `fileDone/fileTotal`
  文件计数。
- 跨条目累计在引擎帧内做被明确禁止（与逐条目 total 分母错配 → done>total 稳态，
  :333-335 carry 注）→ 聚合必须发生在**消费侧**。

**目标**：目录/批量传输全程，面板显示——
① 全批次字节进度条（真百分比，单调前进）；
② 全程速度（跨文件不重置、不被文件切换的 done 回跳污染）；
③ 已完成字节 / 全部字节 + 剩余时间。
同时保留：当前文件名、路由色点、文件计数。

**非目标**：不改单文件帧合同；不做「已传文件数/总文件数」级新语义（fileDone/fileTotal
已有）；不改取消/冲突/回滚语义。

## 2. 用户已拍板的前提

- 总量策略 = **传输前预扫描**（AskUserQuestion 选定）：传输启动前先递归列源目录求
  总字节 → 百分比精确、单调；代价 = SFTP 深树传输起点推迟数秒（用户知情接受）。

## 3. 设计

### 3.1 预扫描（TCCore：OperationEngine）

新纯函数面（可单测，注入式）：

```swift
/// 传输前预扫描整批条目的字节总量（目录树递归求和）。
/// 预算 = 深度 24 / 条目 5000（SFTP 每层一次 listDirectory 往返；
/// 预算超限或任何一次 list/stat 失败 → totalBytes = nil = 总量未知，
/// **传输照常开始**（宁缺毋假，绝不因扫描失败挡传输）。
public struct TransferPlan {
    public let totalBytes: Int64?      // nil = 未知（不定量降级）
    public let entryCount: Int         // 顶层条目数（= 现有 fileTotal 语义）
}
public func planTransfer(_ items: [FileItem], source: FileSource,
                         cancel: CancelFlag?) -> TransferPlan
```

- 只对 `cross-source` 的文件/目录条目递归求和；**同源条目不计**（cp 黑盒由实现方
  经 copyItem(byteProgress:) 自报，聚合基线无法预知其条内量 → 同源批次的 plan
  total 只统计 pump 部分？——裁定：**同源条目按 FileItem.size 计计划量**，cp 路
  聚合帧见 3.3 的 `entryFinished` 上报补齐，两边用同一 plan 数）。
- 取消位检查在每层 listDirectory 前（预扫描本身可取消；取消 → plan=nil 照常传输）。

### 3.2 引擎 → TransferEngine 的条边界回调（协议扩展）
<!-- 实施注记（2026-10-08）：本节 entryFinished 第三重载**未采用**——账本模型
     （§3.3）让引擎自持条目边界，同源 cp 观测直接复用既有 copyItem(byteProgress:)
     帧 + 计划量折算，FileSource 协议零新重载。以下保留原设计作决策记录。 -->


`FileSource.copyItem(from:to:byteProgress:)` 旁新增**默认实现 = 不报**的条边界通道
（加法，与 byteProgress 同法，既有 conformer 零改动）：

```swift
func copyItem(from: TCPath, to: TCPath,
              byteProgress: ((Int64, Int64) -> Void)?,
              entryFinished: ((Int64) -> Void)?) throws
```

`entryFinished(plannedBytes)` = 本条目**已完成**（含被跳过后引擎自行折算），
plannedBytes = 该条目在 plan 中的计划字节（文件 = size；目录 = 预扫描树和；
未知 = 0）。同源 cp 成功、冲突跳过、skipAll 短路**三条路都报**（跳过按计划量
推进 = 设计批准项）。跨源 pump 路由引擎自己持有边界（stream 返回后报，无需
经 FileSource → 该通道仅同源/接缝需要）。

**同服务器 cp 目录的条内 done**：cp 路已有 stat 轮询（directoryTreeBytes 目标树
求和，前一同服务器改动）→ 聚合帧条内分量直接复用轮询 done，无需新轮询。

### 3.3 聚合帧合同（新增参数，不改任何现有参数）

`performCopy/performMove` 新增可选参数：

```swift
aggregate: ((Int64, Int64) -> Void)? = nil   // (整批累计已传字节, plan.totalBytes)
```

引擎内实现（聚合的唯一生产者）：

- `cumulative: Int64` = 已完成条目的计划字节和（含计划外溢出：条目实传 > 计划 →
  按计划计，溢出丢弃——plan 是账本，实测量与它错配时以账本为准，末帧收口）。
- 条目完成 → `cumulative += planned; aggregate?(cumulative, planTotal)`。
- **条内帧**：跨源 pump 路引擎在 stream 每块后 `aggregate?(cumulative + transferred,
  planTotal)`（引擎自己算，不经 FileSource）；同源 cp 路由 copyItem 重载的
  byteProgress 帧换算 = 轮询 done 直接加 cumulative（实现方帧 = 条内值，消费方
  加基线——与 :334 禁的是「帧里偷加」一致，这里是**有账本的集中折算**）。
- `planTotal == nil` → 完全不发聚合帧（不定量路维持现状：扫动条 + 字节数 + 速度
  样本改喂 `cumulative + 条内 done`？——**裁定：不发**，不定量路的速度污染问题
  留给真机反馈，最小改动）。
- 末帧 = `(planTotal, planTotal)`（全部条目走完），与 mergeDirectoryProgress 的
  单文件收口帧互不干扰（不同参数、不同消费者）。
- done 单调钳：消费方再钳一次（引擎保证源单调，消费兜底 = 防御性）。

### 3.4 TransferEngine / 面板（消费侧）

- `TransferProgressInfo` 新增字段：

```swift
let overallBytesDone: Int64?   // 聚合帧值（整批累计）
let overallBytesTotal: Int64?  // plan 总量
```

  构造器默认 nil（既有 5 个测试文件 + 所有构造点零改动）。
- 帧管线：`aggregate` 闭包 → `onProgress(TransferProgressInfo(overall…))`；
  复用 ThrottleState 节流（与 byte 帧同闸），file 级帧**必达**不受节流（维持
  「文件完成即时可见」）。
- 面板 `apply`：`overallBytesDone/overallBytesTotal` 同时存在且 total>0 →
  **进度条/百分比/字节数/速度/剩余全部改用聚合值**（速度样本喂聚合 done →
  跨文件不重置、无 100%→0% 锯齿）；否则 = 现状逻辑（单文件帧 → 条）。
- 当前文件名 = 单文件帧语义不变；标题 fileDone/fileTotal 不变。
- 面板既有直传帧形状测试（TransferPanelDirectRouteTests）不破。

### 3.5 数据流图

```
planTransfer(预扫描) ─→ plan{totalBytes, perEntry}
                             │
 performCopy(aggregate:)     │ 账本 cumulative
   条目边界 ────────────────┴─→ aggregate?(cumulative, total) ─┐
   stream 每块 ────────────────────────────────────────────────┤
   copyItem(byteProgress:) 轮询 done ─→ 基线换算 ──────────────┤
                                                              ↓
 TransferEngine.onProgress → TransferProgressInfo(overall…) → 面板
   有 overall → 条/百分比/速度/剩余用聚合值
   无 overall → 现状（单文件条）
```

## 4. 错误处理

- 预扫描失败（list/stat 抛、预算超限、扫描中被取消）→ `totalBytes=nil`、传输照常、
  面板维持现状（无全进度 ≠ 挡传输）。
- plan 与实传错配（条目中途被删/大小变化）→ 账本为准（按计划量累加），末帧强拉
  `(total,total)`。
- 聚合通道绝不影响既有错误/取消/回滚路径（纯旁路加法；异常路不发聚合帧，面板
  随终态收尾）。

## 5. 测试（TDD 合同锁）

**引擎层（TCCore，假源注入）**：
1. 预扫描 = 树和（含嵌套目录/符号链接按 stat 视 size/预算超限=nil）；
2. 聚合帧序列：条边界帧 + 条内帧 = `(cumulative+条内, total)`、全程单调、末帧 ==
   (total,total)；
3. 跳过条目按计划量推进基线（skip / skipAll 两路）；
4. 同源 cp 路经 entryFinished/轮询换算产聚合帧（黑盒自报合同）；
5. plan=nil → 全程零聚合帧（降级锁）；
6. 预扫描中取消 → plan=nil 传输照常、cancel 语义不变；
7. 既有全量回归（基线 1089，1 skip）。

**TransferEngine 层**：
8. aggregate 帧携带 overall 字段、与 file 帧共存、节流闸（复用 ThrottleState 测试注入
   假时钟）。

**面板层**：
9. `apply` 纯逻辑：overall 存在 → 条/速度用聚合值（速度样本注入假时钟验证跨文件
   不重置）；overall=nil → 现状分支（回归锁）。

**e2e（双 sshd 夹具，环境守卫 skip）**：
10. 跨源目录拷贝（多文件含子目录）：聚合帧存在、done 单调、末帧 == 预扫描 plan；
    面板速度在文件切换瞬间不回 0（样本单调）。

**变异证伪**：把基线加回帧里/删聚合通道 → 对应锁必红。

## 6. 诚实缺口

- SFTP 预扫描成本：深树慢网起点推迟秒级（用户已接受）；预算 5000 条目超限的大目录
  → 无全进度（真机反馈再定要不要调预算/后台补扫）。
- 直传（rsync 接缝）目录条目：plan 有该目录计划量、接缝帧仍单文件 → 聚合的条内
  分量 = cumulative + min(条内 done, 计划溢出丢) ——与跨源路同款账本，直测见锁 2 的
  接缝变体。
- 面板速度样本源切换瞬间的 1~2 帧抖动（节流吸收）；真机定性冒烟。

## 7. 改动文件清单

| 文件 | 改动 |
|---|---|
| Sources/TCCore/Operations/OperationEngine.swift | planTransfer 新面 + aggregate 参数 + 基线/换算逻辑 + 同源/跳过三路 entryFinished |
| Sources/TCCore/FileSource/FileSource.swift | copyItem 第三重载（entryFinished，默认不报） |
| Sources/FlyCommander/Remote/SFTPSource.swift / SFTPClient.swift | copyItem 重载转发（复用 cp 轮询 done） |
| Sources/FlyCommander/Remote/TransferEngine.swift | aggregate 闭包 → 帧管线；TransferProgressInfo 两新字段（默认 nil） |
| Sources/FlyCommander/App/TransferProgressWindowController.swift | apply 优先消费 overall 值 |
| Tests/TCCoreTests/ | 新 TransferPlanProgressTests（锁 1-6） |
| Tests/FlyCommanderTests/ | 引擎帧管线锁 8 / 面板锁 9 / e2e 锁 10 |
