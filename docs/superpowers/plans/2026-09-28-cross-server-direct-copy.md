# 跨 SFTP 服务器双机直传（Direct Server-to-Server Copy）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan team-by-team. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** F5/F6 两端都是 SFTP 且不同服务器时，在源服务器上 exec `rsync -a --progress` 把它自己的文件推到目标服务器（字节不出本机）；做不到就自动回退现有本机中转 pump，传输面板用绿/黄点显示实际路线，直传路带懒总量字节进度 + 速度。

**Architecture:** TCCore `OperationEngine` 加一个**接缝闭包** `directCrossTransfer`（粒度 = 顶层条目），`.handled` 跳过引擎自己的逐文件递归、`.unavailable` 走原 pump（整批粘连）。App 层 `TransferEngine` 接线到接缝：在源 SFTP 连接上 `openExec` 跑 rsync，用 `SSHSession.nextEvent()` 流式截 stderr 解析 per-file 进度行，桥到既有 byteProgress 通道。`CopyRoute` 加 `.directCrossHost` case，面板 routeLabel 前加色点。

**Tech Stack:** Swift 5.9 / AppKit（仅 presentation 层）/ TCCore 纯 Foundation 零 AppKit / Traversio（AGPL SFTP/SSH）/ SPM 单测 + XCUITest。

**Spec:** `docs/superpowers/specs/2026-09-28-cross-server-direct-copy-design.md`（本计划的决策依据，逐条约束）

## Global Constraints

每条都是硬约束，来自用户拍板 / CLAUDE.md / 缩减 SDK 实测：

1. **`--progress`，绝不用 `--info`**：macOS 自带 rsync = openrsync（协议 29），实测
   `--info=progress2` 与 `--info=name` 都是 `unrecognized option`；GNU rsync ≥3.1 才认。
   `-a --progress` openrsync 与 GNU 通吃、无 tty 也输出 per-file 行。
2. **密码绝不进入命令行**：直传只认源机到目标机的密钥信任；密码认证 → 直接
   `.unavailable(.needsAuth)`，绝不开 rsync。命令行只含 user/host/port。
3. **绝不碰用户真实 `~/.ssh`**：测试夹具的 authorized_keys/密钥只进临时目录。
4. **TCCore 零 AppKit，接缝纯 Foundation**：接缝闭包签名不含 Traversio 类型。
5. **绝不动态创建 `DispatchQueue`**（缩减 SDK SIGSEGV）；async→sync 用既有
   `awaitBlocking`（Task + DispatchSemaphore + ResultBox，SFTPClient.swift:372）。
6. **`-oBatchMode=yes` 必在**：源机连目标机需要口令/首次 host key 确认 → 立即失败
   不挂起 → 据此回退。
7. 文案中文在 `L10nStrings.swift` 的中文表，英文在英文表；`L10nKey` 新 case 漏表
   `L10nTests` allCases 双表覆盖锁必红。
8. 提交信息英文；每个 Task 一个可独立评审的提交。
9. **接缝 `.unavailable` = 未传输任何东西**，pump 从干净状态重做整条目；接缝抛错
   = 传输失败直接上抛、不回退（与 pump 抛错同语义）。
10. `swift test` 基线 = 1005 用例 / 1 skip / 0 失败（v0.0.10 全量实测）。

---

## Task 1: TCCore 接缝（DirectOutcome + directCrossTransfer + 引擎接线 + 路由锁）

**Files:**
- Create: `Sources/TCCore/Operations/DirectTransfer.swift`
- Modify: `Sources/TCCore/Operations/OperationEngine.swift`（performCopy 循环、performMove 循环、新增 1 个私有方法）
- Create: `Tests/TCCoreTests/DirectCrossTransferRoutingTests.swift`

**Interfaces:**
- Consumes: `FileItem` / `TCPath` / `ConflictPrompt` / `CancelFlag`（既有）
- Produces（Task 4 依赖这些确切名字）:
  ```swift
  public enum DirectOutcome: Equatable {
      case handled(bytesTransferred: Int64)
      case unavailable(String)
  }
  // OperationEngine 的 public var:
  public var directCrossTransfer: (
      _ item: FileItem,
      _ destDir: TCPath,
      _ byteProgress: ((Int64, Int64) -> Void)?   // (本条目已传, 本条目总量; 0=未知→不定量)
  ) throws -> DirectOutcome
  ```

- [ ] **Step 1: 写失败测试**

`Tests/TCCoreTests/DirectCrossTransferRoutingTests.swift` —— 复制
`OperationEngineRoutingTests.swift` 里的 FakeSource 形状到本文件（那里的 FakeSource 是
private，不可跨文件复用），加两个探针：

```swift
final class DirectCrossTransferRoutingTests: XCTestCase {
    // FakeSource: 从 OperationEngineRoutingTests.swift:11-100 复制（private 不可共享）。
    // 关键记录数组：openReaders / streamWrites / removed / madeDirectories。

    private var src = FakeSource(id: "sftp://a:22")
    private var dst = FakeSource(id: "sftp://b:22")
    private var engine = OperationEngine()

    // MARK: performCopy

    /// .handled → 引擎不开 reader/writer（pump 一行都不跑），条目级进度照常。
    func testHandledSkipsPump() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 10) }
        var bytes: [(Int64, Int64)] = []
        var files: [(Int, Int)] = []
        try engine.performCopy(src.items("a.txt"), to: TCPath("/")!,
                               srcSource: src, dstSource: dst,
                               progress: { files.append(($0, $1)) },
                               byteProgress: { bytes.append(($0, $1)) })
        XCTAssertEqual(src.openReaders.count, 0, "handled 不得开 reader")
        XCTAssertEqual(dst.streamWrites.count, 0, "handled 不得开 writer")
        XCTAssertEqual(bytes, [(10, 10)])
        XCTAssertEqual(files, [(1, 1)])
    }

    /// 接缝拿到的 destDir 就是 destDir.joining(item.name)（冲突处理同点）。
    func testSeamReceivesJoinedDest() throws {
        src.add(file: "a.txt", size: 10)
        var seen: TCPath?
        engine.directCrossTransfer = { _, dest, _ in seen = dest; return .handled(bytesTransferred: 10) }
        try engine.performCopy(src.items("a.txt"), to: TCPath("/tmp")!,
                               srcSource: src, dstSource: dst)
        XCTAssertEqual(seen?.pathString, "/tmp/a.txt")
    }

    /// .unavailable → 走 pump；同批后续条目不再问（粘连）。
    func testUnavailableFallsBackAndStickyForBatch() throws {
        src.add(file: "a.txt", size: 10); src.add(file: "b.txt", size: 10)
        var calls = 0
        engine.directCrossTransfer = { _, _, _ in calls += 1; return .unavailable("nope") }
        try engine.performCopy(src.items("a.txt", "b.txt"), to: TCPath("/")!,
                               srcSource: src, dstSource: dst)
        XCTAssertEqual(calls, 1, "首条目 .unavailable 后同批不得再问")
        XCTAssertEqual(src.openReaders.count, 2, "两条目都须走 pump")
    }

    /// 同源（sourceID 相等）恒不问接缝（cp 快路径不经接缝）。
    func testSameSourceNeverAsks() throws {
        let same = FakeSource(id: "sftp://a:22")
        let sameDst = FakeSource(id: "sftp://a:22")
        var asked = false
        engine.directCrossTransfer = { _, _, _ in asked = true; return .handled(bytesTransferred: 1) }
        try engine.performCopy([fakeItem("a.txt", size: 10)], to: TCPath("/")!,
                               srcSource: same, dstSource: sameDst)
        XCTAssertFalse(asked)
    }

    /// 默认（不注入接缝 = nil）= 行为与本特性诞生前逐字节一致。
    func testNoSeamBehavesAsBefore() throws {
        src.add(file: "a.txt", size: 10)
        try engine.performCopy(src.items("a.txt"), to: TCPath("/")!, srcSource: src, dstSource: dst)
        XCTAssertEqual(src.openReaders.count, 1)
    }

    /// 接缝抛错 → 原样上抛，不回退 pump。
    func testThrowPropagatesNoFallback() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in throw TCError.unknown("boom") }
        XCTAssertThrowsError(try engine.performCopy(src.items("a.txt"), to: TCPath("/")!,
                                                    srcSource: src, dstSource: dst))
        XCTAssertEqual(src.openReaders.count, 0, "抛错后不得再 pump")
    }

    /// 目录条目：接缝处理整棵子树——引擎绝不再递归（不 listDirectory 子项、不 mkdir 目标）。
    func testDirectoryItemGoesWholeToSeam() throws {
        src.addDir("sub")
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 42) }
        try engine.performCopy(src.items("sub"), to: TCPath("/")!, srcSource: src, dstSource: dst)
        XCTAssertEqual(src.listCalls.count, 0, "接缝路引擎不得列目录")
        XCTAssertEqual(dst.madeDirectories.count, 0, "接缝路引擎不得建目标目录")
    }

    /// 目录条目 + 目标已存在同名目录 → 不问接缝（rsync 语义无法表达合并），直接 pump 合并。
    func testExistingDestDirSkipsSeam() throws {
        src.addDir("sub"); dst.addDir("sub")
        var asked = false
        engine.directCrossTransfer = { _, _, _ in asked = true; return .handled(bytesTransferred: 1) }
        try engine.performCopy(src.items("sub"), to: TCPath("/")!, srcSource: src, dstSource: dst)
        XCTAssertFalse(asked, "目标同名目录在位 → 合并语义归 pump，不问接缝")
    }

    /// 冲突 skip → 接缝不被调用、pump 也不跑、条目计入完成。
    func testConflictSkipSkipsSeam() throws {
        src.add(file: "a.txt", size: 10); dst.add(file: "a.txt", size: 1)
        var asked = false
        engine.directCrossTransfer = { _, _, _ in asked = true; return .handled(bytesTransferred: 1) }
        var files: [(Int, Int)] = []
        try engine.performCopy(src.items("a.txt"), to: TCPath("/")!, srcSource: src, dstSource: dst,
                               prompt: { _, _ in .skip },
                               progress: { files.append(($0, $1)) })
        XCTAssertFalse(asked)
        XCTAssertEqual(files, [(1, 1)])
    }

    /// 冲突 overwrite（目标为文件）→ 删除后接缝照问（此时 dst 干净）。
    func testOverwriteRemovesThenAsksSeam() throws {
        src.add(file: "a.txt", size: 10); dst.add(file: "a.txt", size: 1)
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 10) }
        try engine.performCopy(src.items("a.txt"), to: TCPath("/")!, srcSource: src, dstSource: dst,
                               prompt: { _, _ in .overwrite })
        XCTAssertEqual(dst.removed.count, 1)
        XCTAssertEqual(src.openReaders.count, 0)
    }

    /// 取消置位 → 抛 .cancelled，接缝不被调用。
    func testCancelBeatsSeam() throws {
        src.add(file: "a.txt", size: 10)
        let flag = CancelFlag(); flag.cancel()
        engine.directCrossTransfer = { _, _, _ in XCTFail("取消后不得问接缝"); return .unavailable("x") }
        XCTAssertThrowsError(try engine.performCopy(src.items("a.txt"), to: TCPath("/")!,
                                                    srcSource: src, dstSource: dst, cancel: flag))
    }

    /// 多条目：handled 帧的 bytesDone = 已完成条目累计 + 本条目已传。
    func testBytesDoneAccumulatesAcrossItems() throws {
        src.add(file: "a.txt", size: 10); src.add(file: "b.txt", size: 20)
        engine.directCrossTransfer = { item, _, bp in
            bp?(5, item.size); bp?(item.size, item.size)
            return .handled(bytesTransferred: item.size)
        }
        var bytes: [(Int64, Int64)] = []
        try engine.performCopy(src.items("a.txt", "b.txt"), to: TCPath("/")!,
                               srcSource: src, dstSource: dst,
                               byteProgress: { bytes.append(($0, $1)) })
        XCTAssertEqual(bytes, [(5, 10), (10, 10), (15, 20), (30, 20)],
                       "第二条目帧须累计第一条目字节（base=10：5→15、20→30）")
    }

    // MARK: performMove

    /// 移动 + handled → 传完后删源根一次，不 pump。
    func testMoveHandledDeletesSource() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 10) }
        try engine.performMove(src.items("a.txt"), to: TCPath("/")!, srcSource: src, dstSource: dst)
        XCTAssertEqual(src.removed.count, 1)
        XCTAssertEqual(src.openReaders.count, 0)
    }

    /// 移动 + 目录条目 handled → 同样删源根一次（递归删由 fake 记账）。
    func testMoveDirectoryHandledDeletesSource() throws {
        src.addDir("sub")
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 42) }
        try engine.performMove(src.items("sub"), to: TCPath("/")!, srcSource: src, dstSource: dst)
        XCTAssertEqual(src.removed.count, 1)
        XCTAssertEqual(src.listCalls.count, 0)
    }

    /// 移动 + unavailable → pump 路 + 删源（与现状逐字一致）。
    func testMoveUnavailableUsesPumpAndDeletes() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in .unavailable("nope") }
        try engine.performMove(src.items("a.txt"), to: TCPath("/")!, srcSource: src, dstSource: dst)
        XCTAssertEqual(src.openReaders.count, 1)
        XCTAssertEqual(src.removed.count, 1)
    }

    /// 移动 + 目标同名目录在位 → 不问接缝走 pump 合并路；prompt=skip →
    /// copyDirectoryCross 返回 skipped → **不删源**（既有合同原样，接缝零参与）。
    /// （注：无 prompt 时缺省合并**会**删源——那是既有 pump 行为，别锁错方向。）
    func testMoveExistingDestDirNoSeamKeepsSource() throws {
        src.addDir("sub"); dst.addDir("sub")
        engine.directCrossTransfer = { _, _, _ in XCTFail("合并路不问接缝"); return .unavailable("x") }
        try engine.performMove(src.items("sub"), to: TCPath("/")!, srcSource: src, dstSource: dst,
                               prompt: { _, _ in .skip })
        XCTAssertEqual(src.removed.count, 0, "skip 决策 → 不得删源")
    }
}
```

（FakeSource 需自带 `add(file:size:)` / `addDir(_:)` / `items(_:)` / `listCalls` 记录——照
`OperationEngineRoutingTests.swift` 的 FakeSource 补最小实现：`listDirectory` 记录调用并
返回该目录内容表；`stat` 查表；`copyItem`/`moveItem`/`removeItem`/`makeDirectory`/
`openReader`/`streamWrite` 各自追加记录。fakeItem 工厂 size 用参数。）

- [ ] **Step 2: 跑测试确认编译失败（类型不存在）**

Run: `swift test --filter DirectCrossTransferRoutingTests 2>&1 | tail -20`
Expected: 编译错误 `cannot find 'DirectOutcome' in scope`

- [ ] **Step 3: 最小实现**

`Sources/TCCore/Operations/DirectTransfer.swift`：

```swift
import Foundation

/// 跨机直传接缝的结果。
public enum DirectOutcome: Equatable {
    /// 本条目已整体完成（rsync 成功）；bytesTransferred = 实传字节。
    case handled(bytesTransferred: Int64)
    /// 直传不可用（原因串）——调用方走 pump。契约：**未传输任何字节**。
    case unavailable(String)
}
```

`OperationEngine.swift` 修改（三处）：

1. 类顶部加字段（`private let fm` 之后）：

```swift
    /// 跨机直传接缝（App 层注入；nil = 永远 pump）。粒度 = 顶层条目：
    /// `.handled` 时**整条（含整棵目录树）已由实现方完成**，引擎不得再递归；
    /// `.unavailable` 时**未传输任何字节**，引擎从干净状态走 pump。
    /// 启用条件（两端皆 sftp 且不同服务器）由注入方自查，引擎不看 source 类型。
    /// 契约：后台线程调用；抛错 = 传输失败（不回退）；byteProgress 第二参 0 = 总量未知。
    public var directCrossTransfer: (
        (_ item: FileItem, _ destDir: TCPath, _ byteProgress: ((Int64, Int64) -> Void)?) throws -> DirectOutcome
    )?
```

2. 私有方法 `askDirect`（`resolveConflict` 之后加，代码见下条定稿块内）。
   守卫逻辑（目标同名目录在位 → 接缝零调用）**内联在循环里**——守卫若单独成函数
   还弹 prompt 再交 copyDirectoryCross 弹第二次 = 双弹窗回归，故守卫只 stat 不弹，
   合并/ask-once/skip 语义归 copyDirectoryCross 一字不碰。

3. `performCopy` 循环改造——**完整定稿**（`lastTotals` 旁加 `var directFailed = false`
   与 `var directBase: Int64 = 0`；循环体替换为下述形状，注释处为原逻辑原样保留）。
   要点：接缝询问点 = 文件条目在 `resolveConflict` 之后 `stream` 之前（冲突语义自动
   对齐），目录条目在 `copyDirectoryCross` 之前、且目标同名目录在位时**零调用**：

```swift
    private func askDirect(_ item: FileItem, _ dst: TCPath,
                           byteProgress: ((Int64, Int64) -> Void)?,
                           directBase: inout Int64) throws -> DirectOutcome {
        guard let seam = directCrossTransfer else { return .unavailable("no seam") }
        let base = directBase                      // 值快照：Swift 闭包捕获 var 是引用语义
        let wrapped: ((Int64, Int64) -> Void)? = byteProgress.map { bp in
            { done, total in bp(total > 0 ? done + base : done, total) }   // total=0 → 不定量
        }
        return try seam(item, dst, wrapped)
    }
```

`performCopy` 循环体（对照原 :33-59 逐行改，`// →` 注释标改动）：

```swift
        for (i, item) in items.enumerated() {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            let dst = destDir.joining(item.name)
            if cross, item.isDirectory {
                // 守卫：目标同名目录在位 → 合并语义归 pump，接缝零调用。
                let destIsDir = directCrossTransfer != nil && !directFailed
                    && (try? dstSource.stat(dst))?.isDirectory == true
                if !destIsDir, directCrossTransfer != nil, !directFailed {
                    switch try askDirect(item, dst, byteProgress: byteProgress, directBase: &directBase) {
                    case .handled(let bytes):
                        directBase += max(0, bytes)
                        progress?(i + 1, total)
                        continue                                   // 整树已完成，引擎不递归
                    case .unavailable: directFailed = true          // sticky
                    }
                }
                // ↓ 原 copyDirectoryCross + mergeDirectoryProgress 两行原样
            } else {
                if try resolveConflict(...) { progress?(i + 1, total); continue }   // 原样
                if cross {
                    // 文件：resolveConflict 已保证目标干净（不存在或覆盖已删）→ 可问。
                    if directCrossTransfer != nil, !directFailed,
                       case .handled(let bytes) = try askDirect(item, dst, byteProgress: byteProgress,
                                                                directBase: &directBase) {
                        directBase += max(0, bytes)
                        progress?(i + 1, total)
                        continue
                    } else if directCrossTransfer != nil { directFailed = true }
                    // ↓ 原 stream(...) 调用原样（directFailed 落此处）
                } else {
                    try dstSource.copyItem(from: item.path, to: dst)   // 原样
                }
            }
            progress?(i + 1, total)
        }
```

`performMove` 循环同形：cross 目录分支 = 守卫 + askDirect，`.handled` →
`do { try srcSource.removeItem(at: item.path) } catch { onWarning?(item.name, asTCError(error)) }`
再 `progress?(i+1, total); continue`；unavailable → directFailed=true 落原合并路（其
skipped→不删源合同原样）。文件分支同 performCopy 改形，`.handled` 后删源（同
onWarning 合同）。**performMove 的 catch 回滚语义不受影响**：接缝抛错进 catch，
`rolledBack` 此时为空（跨源路从不 append），throw asTCError 原样上抛——与 pump 抛错同路。

条目间帧跳变（N%→100%→下一条目小%）= pump 逐文件观感一致，可接受。「接缝被调用
与否」全部用 **seamCalls 计数断言**（`testExistingDestDirSkipsSeam` 证 called==0），
不用返回值猜。`DirectAttemptResult.skippedUnresolvedConflict` 在守卫简化后已无产出方
——保留 case 仅作穷举占位，或直接删（实现者二选一，删则同步删 enum 与用例引用）。

- [ ] **Step 4: 跑路由锁**

Run: `swift test --filter DirectCrossTransferRoutingTests 2>&1 | tail -5`
Expected: `Test Suite 'DirectCrossTransferRoutingTests' passed`

- [ ] **Step 5: 全量回归（接缝默认 nil = 现状不变）**

Run: `swift test 2>&1 | tail -5`
Expected: 全绿（基线 1005 + 新增用例，1 skip）

- [ ] **Step 6: 变异证伪**

把 `performCopy` 里 `case .handled` 的 `continue` 删掉（handled 后仍走 pump）→
`testHandledSkipsPump` 必红；粘连判定反（每条目都重置）→ `testUnavailableFallsBackAndStickyForBatch`
必红。验证后恢复。

- [ ] **Step 7: Commit**

```bash
git add Sources/TCCore/Operations/DirectTransfer.swift Sources/TCCore/Operations/OperationEngine.swift Tests/TCCoreTests/DirectCrossTransferRoutingTests.swift
git commit -m "feat(core): direct cross-server transfer seam (per-item handoff, sticky fallback)"
```

---

## Task 2: CopyRoute 扩展 + L10n 新键 + 面板色点

**Files:**
- Modify: `Sources/FlyCommander/Remote/SFTPClient.swift:281-286`（RelayReason +2 case）
- Modify: `Sources/FlyCommander/Remote/SFTPClient.swift:275-278`（CopyRoute +1 case）
- Modify: `Sources/TCCore/L10n/L10nKey.swift:103-104`、`Sources/TCCore/L10n/L10nStrings.swift:166-170,359-363`
- Modify: `Sources/FlyCommander/App/TransferProgressWindowController.swift`（routeText + 色点）
- Modify: `Tests/FlyCommanderTests/TransferProgressPanelTests.swift`（追加用例）
- Modify: 所有对 RelayReason/CopyRoute 的穷举 switch（编译器强制找全：`grep -rn "case .cpMissing\|case .execRejected\|case serverSide\|case .serverSide" Sources/`）

**Interfaces:**
- Consumes: 无
- Produces（Task 4/5 依赖）:
  ```swift
  public enum CopyRoute: Equatable {
      case serverSide
      case directCrossHost            // 跨服务器 rsync 直传（字节不出服务器对）
      case relayed(RelayReason)
  }
  public enum RelayReason: Equatable {
      case execRejected, cpMissing, unsupportedFlags, channelGone
      case needsAuth                  // 双机免密信任未建立（或 B 端密码认证）
      case rsyncMissing               // 源服务器无 rsync（exit 127）
  }
  // L10nKey 新 case: transDirectCrossHost, transRelayedNeedsAuth, transRelayedRsyncMissing
  ```

- [ ] **Step 1: 写失败测试**（`TransferProgressPanelTests.swift` 追加）

```swift
    // MARK: - 直传色点 + 文案（spec §3）

    func testRouteTextDirectAndNewReasons() {
        XCTAssertEqual(TransferProgressWindowController.routeText(.directCrossHost),
                       L10n.t(.transDirectCrossHost))
        XCTAssertEqual(TransferProgressWindowController.routeText(.relayed(.needsAuth)),
                       L10n.t(.transRelayedNeedsAuth))
        XCTAssertEqual(TransferProgressWindowController.routeText(.relayed(.rsyncMissing)),
                       L10n.t(.transRelayedRsyncMissing))
    }

    /// 色点：绿 = serverSide|directCrossHost；黄 = relayed(任意原因)。
    /// apply(route:) 把点色写进可探属性（真窗色彩断言在缩减 SDK 下不稳，探针先例）。
    func testDotColorThreeStates() {
        let wc = TransferProgressWindowController.createWithoutPresentingForTest()
        wc.applyProbeRoute(.serverSide)
        XCTAssertEqual(wc.probe.routeDotGreen, true)
        wc.applyProbeRoute(.directCrossHost)
        XCTAssertEqual(wc.probe.routeDotGreen, true)
        wc.applyProbeRoute(.relayed(.needsAuth))
        XCTAssertEqual(wc.probe.routeDotGreen, false)
        wc.applyProbeRoute(nil)
        XCTAssertNil(wc.probe.routeDotGreen, "无 route = 点隐藏（属性为 nil）")
    }
```

（`wc.probe` 若尚无 `routeDotGreen`/`applyProbeRoute`，在 TransferProgressWindowController
的 test probe 结构里加：`routeDotGreen: Bool?` 由内部 `apply(route: CopyRoute?)` 写入——
`route == nil → nil`，否则 `= (route == .serverSide || route == .directCrossHost)`。
probe 先例 = 现有 `p.bar`/`p.cancel`。）

- [ ] **Step 2: 跑红**（新 case 不存在编译错）

Run: `swift build 2>&1 | head -10`
Expected: `type 'RelayReason' has no member 'needsAuth'` 等

- [ ] **Step 3: 实现**

`SFTPClient.swift`：`CopyRoute` 加 `case directCrossHost`（注释：跨服务器 rsync 直传，
字节不出服务器对）；`RelayReason` 加 `case needsAuth`（双机免密信任未建立）与
`case rsyncMissing`（源服务器无 rsync）。

`L10nKey.swift` 103-104 行组追加：
`transDirectCrossHost, transRelayedNeedsAuth, transRelayedRsyncMissing`。

`L10nStrings.swift` 英文表（166-170 区）：
```swift
.transDirectCrossHost: "Direct server-to-server",
.transRelayedNeedsAuth: "Relayed via this Mac (no key trust between servers)",
.transRelayedRsyncMissing: "Relayed via this Mac (no rsync on source server)",
```
中文表（359-363 区）：
```swift
.transDirectCrossHost: "双机直传",
.transRelayedNeedsAuth: "本机中转（双机免密信任未建立）",
.transRelayedRsyncMissing: "本机中转（源服务器没有 rsync）",
```

routeText（:278-289）加三个分支。色点：routeLabel 行前加 8×8 `NSView`（wantsLayer，
`layer.backgroundColor` 绿 = `NSColor.systemGreen.cgColor` / 黄 = `NSColor.systemYellow.cgColor`），
约束 leading 对齐 routeLabel 基线区、宽高 8 固定、`translatesAutoresizingMaskIntoConstraints = false`
（缩减 SDK 铁律）；`apply(route:)` 里设 hidden + 色 + probe 写入。现有 routeLabel 的
leading 约束改为跟随色点 trailing+4pt（若 routeLabel 约束是相对 contentLayoutGuide，
把色点摆其前、routeLabel 改相对色点）。

- [ ] **Step 4: 全量编译 + 测试**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 全绿（`L10nTests` allCases 覆盖锁验证双表；穷举 switch 编译错即漏网 case，补全）

- [ ] **Step 5: 变异证伪**：色点条件里删 `|| route == .directCrossHost` → `testDotColorThreeStates` 红；恢复。

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests/FlyCommanderTests/TransferProgressPanelTests.swift
git commit -m "feat(ui): directCrossHost route + green/yellow dot on transfer panel"
```

---

## Task 3: rsync 命令构造 + 失败分类 + `--progress` 解析器（纯函数）

**Files:**
- Create: `Sources/FlyCommander/Remote/DirectRsync.swift`
- Create: `Tests/FlyCommanderTests/DirectRsyncTests.swift`

**Interfaces:**
- Consumes: `ServerSideCopy.shellQuote`（SFTPClient.swift:298，internal，同 target 可复用）
- Produces（Task 4 依赖）:
  ```swift
  enum DirectRsync {
      struct ItemTarget { let remotePath: String; let dstPath: String; let isDirectory: Bool }
      struct Peer { let host: String; let port: UInt16; let username: String }
      static func command(item: ItemTarget, peer: Peer) -> String
      static func classify(exitStatus: UInt32?, stderr: String) -> ServerSideCopy.Result
  }
  final class RsyncProgressParser {
      struct Event { let fileName: String?; let fileBytesDone: Int64; let fileBytesTotal: Int64; let fileDone: Int; let fileTotal: Int }
      var onEvent: ((Event) -> Void)?
      func feed(_ text: String)
      var fileBytesDone: Int64       // 末文件行值 或 已完成累计（无行时）
      var totalKnown: Bool
      var fileDone: Int
      var fileTotal: Int
  }
  ```

- [ ] **Step 1: 写失败测试** `Tests/FlyCommanderTests/DirectRsyncTests.swift`

```swift
import XCTest
@testable import FlyCommander

final class DirectRsyncTests: XCTestCase {
    private func peer(_ port: UInt16 = 22) -> DirectRsync.Peer {
        DirectRsync.Peer(host: "10.0.0.2", port: port, username: "bob")
    }

    // MARK: 命令构造（spec §2；变异证伪：删 BatchMode/-p/尾斜杠/quote 任一 → 对应断言红）

    func testCommandFileStandardPort() {
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/srv/a.txt", dstPath: "/srv2/a.txt", isDirectory: false),
            peer: peer())
        // dstPath 是全路径（接缝传 destDir.joining(name)）；user@host: 前缀裸露，
        // 仅对冒号后的路径 shellQuote（远端 ssh 在 B 上再解一层引用）。
        XCTAssertEqual(cmd,
            #"rsync -a --progress -e 'ssh -oBatchMode=yes' -- '/srv/a.txt' bob@10.0.0.2:'/srv2/a.txt'"#)
    }

    func testCommandDirectoryTrailingSlashes() {
        // 目录：源尾斜杠=拷内容不嵌套（spec 拍板）；目标同样带尾斜杠
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/srv/sub", dstPath: "/srv2/sub", isDirectory: true),
            peer: peer(2222))
        XCTAssertEqual(cmd,
            #"rsync -a --progress -e 'ssh -oBatchMode=yes -p 2222' -- '/srv/sub/' bob@10.0.0.2:'/srv2/sub/'"#)
    }

    func testCommandQuotesEvilPaths() {
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/srv/it's $(rm -rf /)", dstPath: "/srv2/x", isDirectory: false),
            peer: peer())
        XCTAssertTrue(cmd.contains(#"'/srv/it'\''s $(rm -rf /)'"#), "shellQuote 语义必须生效: \(cmd)")
    }

    /// 密码/凭据绝不入命令行——命令行里除 user@host 外不含 auth 材料（结构性保证：
    /// Peer 根本没有 auth 字段；此锁防未来有人往 Peer 塞密码再拼 -e sshpass）。
    func testNoSecretInCommand() {
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/a", dstPath: "/b", isDirectory: false), peer: peer())
        for needle in ["sshpass", "password"] {
            XCTAssertFalse(cmd.lowercased().contains(needle), "命令行出现 \(needle)：密码泄漏面")
        }
    }

    // MARK: classify（exit/stderr → Result；与 ServerSideCopy.classify 同形状、不同分类表）

    func testClassifyOk() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: 0, stderr: ""), .ok)
    }
    func testClassifyRsyncMissing() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: 127, stderr: "rsync: command not found"),
                       .relay(.rsyncMissing))
    }
    func testClassifyNeedsAuthPatterns() {
        for s in ["Permission denied (publickey,password).",
                  "Host key verification failed.",
                  "Connection refused",
                  "Could not resolve hostname bogus",
                  "ssh: Could not resolve hostname"] {
            XCTAssertEqual(DirectRsync.classify(exitStatus: 1, stderr: s), .relay(.needsAuth), s)
        }
    }
    func testClassifyGenericFailureNoFallback() {
        // 磁盘满/权限等真失败 → fail 不回退（与同源 cp 政策逐字一致）
        if case .fail = DirectRsync.classify(exitStatus: 1, stderr: "rsync: write failed: No space left on device") { }
        else { XCTFail("应为 .fail") }
    }
    func testClassifyNoExitStatusChannelGone() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: nil, stderr: "x"), .relay(.channelGone))
    }
    func testClassifyEmptyStderrNonZeroChannelGone() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: 1, stderr: "  "), .relay(.channelGone))
    }

    // MARK: --progress 解析器（真机实测样例）

    /// openrsync 实测双行式（macOS 源机，无 tty）：
    func testParserOpenrsyncRealSample() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("a.txt\n              6 100%  390.10KB/s   00:00:00 (xfer#1, to-check=1/2)\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].fileName, "a.txt")
        XCTAssertEqual(events[0].fileBytesDone, 6)
        XCTAssertEqual(events[0].fileBytesTotal, 6)   // 100% → done == total
        XCTAssertEqual(events[0].fileDone, 1)
        XCTAssertEqual(events[0].fileTotal, 2)
        XCTAssertTrue(p.totalKnown)
    }

    /// GNU rsync 3.x 中间态：total 与 done 分离（85%）。
    func testParserGnuPartialPercent() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("dir/b.bin\n     1000  1000   85%  1.23MB/s   00:00:02 (xfer#1, to-check=2/3)\n")
        XCTAssertEqual(events.last?.fileBytesDone, 1000)
        XCTAssertEqual(events.last?.fileBytesTotal, 1000)  // done==total 且 85%？→ 见下注
    }
}
```

**解析规则拍板**（写进 DirectRsync.swift 头注释，锁随之定稿）：
- 状态机：非空非进度行 = 文件名挂起；`<done> <total> <pct>% <rate> <eta> (xfer#N, to-check=i/T)`
  行（或 openrsync 的 `<done> <pct>% …` 三字段变体）= 挂起名 + 数值提交一个事件。
- `fileBytesTotal`：GNU 五字段式 = total 字段；openrsync 式（done 后直接 pct）=
  done 按 pct 反推（`pct>0 ? done*100/pct : done`，整型即够——UI 只用于百分比）。
  上面 GNU 样例 done=1000 total=1000 85% 是自相矛盾的坏样例——换成
  `1000 1176 85%`（done/total/percent 一致）；锁按一致样例写，**不一致时信 total**。
- `(xfer#N, to-check=i/T)` 尾巴：`to-check=T/T`（i==T）时 fileDone=该值；否则
  fileDone=N（xfer 计数）。尾巴缺失 → fileDone/fileTotal 保持前值不报错。
- 百分比字段缺失（纯 `--progress` 老式）→ 事件照发，total 反推失败则 total=done。
- 乱码/无比例行：忽略不抛、不产生事件。
- `feed` 可被任意分块调用（chunk 边界落在行中间也行：内部留 tail 缓冲）。

修正后的 GNU 锁样例（替换上条）：

```swift
    func testParserGnuPartialPercent() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("dir/b.bin\n     1000 1176  85%  1.23MB/s   00:00:02\n")
        XCTAssertEqual(events.last?.fileBytesDone, 1000)
        XCTAssertEqual(events.last?.fileBytesTotal, 1176)
    }

    /// 跨 chunk 半行拼接 + 尾巴缺失容忍。
    func testParserSplitAcrossChunksAndNoTail() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("b.txt\n   500 1000  50%  9")
        XCTAssertTrue(events.isEmpty, "半行不得出事件")
        p.feed(".9KB/s   00:00:00\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].fileBytesTotal, 1000)
        XCTAssertEqual(p.fileDone, 0, "尾巴缺失 → fileDone 保持 0（面板不显示文件计数）")
    }

    /// 多文件累计：文件间字节单调。
    func testParserMultiFileMonotonic() {
        let p = RsyncProgressParser()
        p.feed("a\n   6   6 100%  10B/s  0:00 (xfer#1, to-check=1/2)\n")
        p.feed("b\n  10  10 100%  10B/s  0:00 (xfer#2, to-check=2/2)\n")
        XCTAssertEqual(p.fileBytesDone, 16)   // 末行 done + 前文件累计
        XCTAssertEqual(p.fileDone, 2)
        XCTAssertEqual(p.fileTotal, 2)
    }

    /// 垃圾输入不抛不产事件（降级无进度，绝不判失败）。
    func testParserGarbageIgnored() {
        let p = RsyncProgressParser()
        var n = 0
        p.onEvent = { _ in n += 1 }
        p.feed("rsync: hello\x{00FF}乱码???\n\n")
        XCTAssertEqual(n, 0)
    }
```

- [ ] **Step 2: 跑红** Run: `swift test --filter DirectRsyncTests 2>&1 | head -5`（编译错=红）

- [ ] **Step 3: 实现 `Sources/FlyCommander/Remote/DirectRsync.swift`**

```swift
import Foundation

/// 跨机直传的纯函数面：rsync 命令构造 + 失败分类 + `--progress` 输出解析。
/// 全部无 IO 无线程——e2e 之外的行为都锁在这层。
///
/// 命令规格（spec §2，三轮修订）：**只用 --progress，绝不用 --info**——macOS 自带
/// openrsync（协议 29）不认 --info=progress2/--info=name（实测 unrecognized option），
/// GNU rsync ≥3.1 才认；`-a --progress` 两方言通吃且无 tty 也输出。
/// `-oBatchMode=yes`：源机→目标机需要口令/首次指纹 → 立即失败不挂起 → 回退。
enum DirectRsync {
    /// dstPath = **完整目标路径**（非父目录）——接缝收到的 destDir 即 destDir.joining(name)
    /// 已是全路径（Task 1 testSeamReceivesJoinedDest 锁死），此处不得再拼一次名。
    /// isDirectory 只决定 src/dst 尾斜杠（源尾斜杠=拷内容不嵌套）。
    struct ItemTarget {
        let remotePath: String
        let dstPath: String
        let isDirectory: Bool
    }
    struct Peer { let host: String; let port: UInt16; let username: String }
    // **Peer 故意没有 auth/密码字段**：直传只认 A→B 密钥信任，密码绝不入命令行。

    static func command(item: ItemTarget, peer: Peer) -> String {
        let portPart = peer.port == 22 ? "" : " -p \(peer.port)"
        let slash = item.isDirectory ? "/" : ""
        let src = item.remotePath + slash
        let dst = item.dstPath + slash
        let dstURI = "\(peer.username)@\(peer.host):\(ServerSideCopy.shellQuote(dst))"
        return "rsync -a --progress -e 'ssh -oBatchMode=yes\(portPart)' -- "
            + "\(ServerSideCopy.shellQuote(src)) \(dstURI)"
    }
    // 无 lastPathComponent 重拼 = 无「src 尾斜杠吞掉路径名」类坑（早先草稿在此踩过）。

    /// 失败分类表（spec §2）：与 ServerSideCopy.classify 同形状、不同表。
    /// needsAuth 串集：ssh/rsync 对「认证不过/连不上对端」的原话。
    static func classify(exitStatus: UInt32?, stderr: String) -> ServerSideCopy.Result {
        guard let status = exitStatus else { return .relay(.channelGone) }
        if status == 0 { return .ok }
        if status == 127 { return .relay(.rsyncMissing) }
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty { return .relay(.channelGone) }
        let authMarks = ["Permission denied", "Host key verification failed",
                         "Connection refused", "Could not resolve hostname"]
        if authMarks.contains(where: msg.contains) { return .relay(.needsAuth) }
        return .fail(msg)   // 真失败：带 stderr 上抛不回退（cp 同政策）
    }
}

/// `rsync -a --progress` stderr 解析器（openrsync/GNU 双方言）。
/// 行形态（实测样例见 DirectRsyncTests）：文件名行 + `<done> [total] <pct>% <rate>
/// <eta> (xfer#N, to-check=i/T)` 行。喂文本（可半行），事件回调。
/// 铁律：**任何解析失败 = 忽略该段文本**，绝不抛错、绝不判传输失败（spec §2）。
final class RsyncProgressParser {
    struct Event { let fileName: String?; let fileBytesDone: Int64
                   let fileBytesTotal: Int64; let fileDone: Int; let fileTotal: Int }
    var onEvent: ((Event) -> Void)?
    private(set) var fileBytesDone: Int64 = 0   // 已完成文件累计 + 当前行 done
    private(set) var totalKnown = false
    private(set) var fileDone = 0
    private(set) var fileTotal = 0
    private var tail = ""            // 跨 chunk 半行缓冲
    private var pendingName: String? // 文件名行挂起

    func feed(_ text: String) {
        tail += text
        // rsync 用 \r 原地刷新：\r 与 \n 都是行界，每行当最新态（事件幂等覆盖）。
        var lines = tail.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        tail = lines.removeLast()                 // 末段可能半行，留缓冲
        for line in lines { ingest(line) }
    }

    private func ingest(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        // 数值行判定：首字段是数字。不是 → 当文件名行挂起。
        let fields = t.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = fields.first, first.allSatisfy(\.isNumber),
              let done = Int64(first) else {
            pendingName = t
            return
        }
        // done 后跟 [total] <pct>%：第二字段是纯数字 = GNU total；否则 openrsync 式
        // （done 后直接 <pct>%，total 由 pct 反推）。字段形态认不全 → 忽略该行不抛。
        var total: Int64?
        var percent: Int64?
        if fields.count >= 3, fields[1].allSatisfy(\.isNumber), fields[2].hasSuffix("%"),
           let p = Int64(fields[2].dropLast()) {
            total = Int64(fields[1]); percent = p
        } else if fields.count >= 2, fields[1].hasSuffix("%"),
                  let p = Int64(fields[1].dropLast()) {
            total = p > 0 ? done * 100 / p : done          // openrsync 反推（整型够用）
            percent = p
        } else { return }                                   // 认不全 = 忽略，绝不抛
        // (xfer#N, to-check=i/T) 尾巴：缺失容忍（fileDone 保持前值）。解析认不全整段跳过。
        if let tc = t.range(of: "to-check="),
           let slash = t[tc.upperBound...].firstIndex(of: "/") {
            let iStr = String(t[tc.upperBound..<slash]).trimmingCharacters(in: .whitespaces)
            let tStr = String(t[index(after: slash)...).prefix(while: { $0.isNumber })
            if let i = Int(iStr), let tot = Int(tStr), tot > 0 {
                fileTotal = tot
                fileDone = i == tot ? tot : fileDone   // 中间态不动 fileDone
            }
        }
        let evTotal = max(total ?? done, done)     // 不一致时信 total；无 total 信 done
        if total != nil { totalKnown = true }
        let completing = (percent == 100) || (total != nil && done >= total)
        let event = Event(fileName: pendingName, fileBytesDone: cumulative + done,
                          fileBytesTotal: evTotal, fileDone: fileDone, fileTotal: fileTotal)
        if completing { cumulative += done }       // 累计推进发生在发事件**之后**
        pendingName = nil
        fileBytesDone = cumulative + (completing ? 0 : done)
        onEvent?(event)
    }
    private var cumulative: Int64 = 0   // 已完成文件字节和
}
```

（骨架里 cumulative/done 的「当前文件并入累计」时机 = `testParserMultiFileMonotonic`
锁死：末行 done 后 `p.fileBytesDone == 16`（6+10）。骨架与此锁冲突时**以测试锁为准**
——这是全计划惯例：测试是行为合同，正文代码是建议。）

- [ ] **Step 4: 全绿** Run: `swift test --filter DirectRsyncTests && swift test 2>&1 | tail -3`

- [ ] **Step 5: 变异证伪**：classify 删 "Host key verification failed" → 对应锁红；
  解析器把 fail 判事件 → `testParserGarbageIgnored` 红。恢复。

- [ ] **Step 6: Commit**

```bash
git add Sources/FlyCommander/Remote/DirectRsync.swift Tests/FlyCommanderTests/DirectRsyncTests.swift
git commit -m "feat(remote): rsync command builder, failure classifier, --progress parser (pure)"
```

---

## Task 4: SFTPConnection.runRsyncDirect + SFTPSource 连接面 + TransferEngine 接线

**Files:**
- Modify: `Sources/FlyCommander/Remote/SFTPClient.swift`（SFTPConnection 新增直传方法）
- Modify: `Sources/FlyCommander/Remote/SFTPSource.swift`（暴露 runDirectCross + peer）
- Modify: `Sources/FlyCommander/Remote/TransferEngine.swift`（接缝注入 + 独立源 peer）
- Create: `Tests/FlyCommanderTests/DirectConnectionProbeTests.swift`（环境守卫集成测试）
- Modify: `Tests/FlyCommanderTests/TransferPanelDirectRouteTests.swift`（新建，字节帧桥接锁）

**Interfaces:**
- Consumes: Task 1 `engine.directCrossTransfer` 签名、Task 3 `DirectRsync.*`
- Produces:
  ```swift
  // SFTPConnection:
  func runDirectRsync(item: DirectRsync.ItemTarget, peer: DirectRsync.Peer,
                      totalHint: Int64?,
                      byteProgress: ((Int64, Int64) -> Void)?,
                      cancel: CancelFlag?) throws -> DirectOutcome
  // SFTPSource（转发 + 存在性守卫）:
  var peer: DirectRsync.Peer { get }
  func runDirectRsync(...) throws -> DirectOutcome
  ```

- [ ] **Step 1: 环境守卫集成测试（先红）** `DirectConnectionProbeTests.swift`

夹具 = 双 `SFTPServerFixture`（照抄 `SFTPToSFTPTransferTests.swift` 的 setUp/tearDown/
makeSource/runWithTimeout 形状——那里已解决双 sshd、TOFU 域隔离、超时防死锁三件事）。
本夹具的 A、B **不注入** A→B 信任（fixture 各发各的密钥），所以锁的是
**回退路**——直传尝试真实跑通 exec 通道 → ssh 被 BatchMode 拒 → `.unavailable(.needsAuth)`
→ pump 完成整批。信任在场 + 真 rsync 的正路 e2e 依赖本机 sshd 配置允许 root 域
authorized_keys 注入，先由 Step 1.5 spike 判定（见下）。

```swift
    /// 无 A→B 信任：跨服务器复制目录 = 直传尝试→needsAuth→pump 完成，route=relayed(.needsAuth)。
    func testNoTrustFallsBackToPumpAndCompletes() throws {
        // A 根下写 sub/{a.txt(1KB), deep/b.txt(2KB)}；B 空。
        // engine.directCrossTransfer 接 src A 源的 runDirectRsync。
        // 断言：目标树逐文件字节一致；(dstSource as? SFTPSource)?.lastCopyRoute
        //       == .relayed(.needsAuth)（经 TransferEngine 语义：由接缝回抛原因单测
        //       引擎侧 Task 1 已锁；此处锁真实 ssh exec 路径产 .unavailable 不挂起）。
        // 超时 60s 包裹（BatchMode 若失效会挂——超时即红灯，正是变异）。
    }
```

- [ ] **Step 1.5: 可行性 spike（spike=一次性脚本，不入仓）**

双 fixture 起好后手工验证 A 账户 `~/.ssh/authorized_keys` 注入 fixture 客户端公钥
（fixture 账户 home = `live.remoteBase`，StrictModes off 已关，写
`remoteBase/.ssh/authorized_keys` 即可），再跑 A→B 的 `ssh -oBatchMode=yes`（B 用 A
连接同一密钥 + `StrictHostKeyChecking=no -oUserKnownHostsFile=<临时>`）。**通** →
追加正向 e2e（下面 testDirectTrustCompletesWithoutLocalBytes）；**不通**（本机 sshd
策略限制）→ 如实降级：正向由 Task 3 纯函数锁 + Task 1 fake 锁 + Task 5 假路由 UI 锁
覆盖，本 Step 只留回退锁。结论写进测试文件头注释。

```swift
    /// （spike 通才有）A→B 信任在场：跨服务器目录复制走 .handled，
    /// 目标树逐文件字节一致 + lastCopyRoute == .directCrossHost，且 pump 计数为 0。
    func testDirectTrustCompletesWithoutLocalPump() throws { ... }
```

- [ ] **Step 2: SFTPConnection.runDirectRsync**（SFTPClient.swift，copyFile 之后）

```swift
    /// 跨服务器直传：本连接（A）上 exec rsync 推到 peer（B）。**不持 SFTP lock**
    /// （exec 通道独立于 sftp 子系统；持锁会把目标窗格浏览挡到 rsync 结束——
    /// copyFile 持锁是两阶段秒级操作，rsync 可分钟级，语义不同）。
    /// 认证前提：A→B 密钥信任在场；B 需要口令 → -oBatchMode=yes 立即失败。
    /// 调用方（TransferEngine）保证在后台线程。
    func runDirectRsync(item: DirectRsync.ItemTarget, peer: DirectRsync.Peer,
                        totalHint: Int64?,
                        byteProgress: ((Int64, Int64) -> Void)?,
                        cancel: CancelFlag?) throws -> DirectOutcome {
        do {
            return try awaitBlocking { () -> DirectOutcome in
                let session: SSHSession
                do { session = try await self.conn.openExec(DirectRsync.command(item: item, peer: peer)) }
                catch { return .unavailable(ServerSideCopy.relayReason(for: error).describe) }
                defer { Task { await session.close() } }   // 取消/结束统一关通道 → 远端 rsync 收 SIGHUP
                let parser = RsyncProgressParser()
                var stderrBuf = Data()
                var exit: UInt32?
                var cancelled = false
                while true {
                    if cancel?.isCancelled == true { cancelled = true; break }
                    // nextEvent 真抛 = 通道级异常 → 内层 do/catch 接住（见循环外注释），
                    // 转 .unavailable(relayReason(for:))；仅 cancel 的 .cancelled 上抛不回退。
                    let ev: SSHSessionEvent?
                    do { ev = try await session.nextEvent() }
                    catch { return .unavailable(ServerSideCopy.relayReason(for: error).diagnosticCode) }
                    guard let ev else { break }   // nil = 通道关
                    switch ev {
                    case .standardOutput(let b): parser.feed(String(decoding: b, as: UTF8.self))
                    case .standardError(let b):
                        stderrBuf.append(contentsOf: b)
                        parser.feed(String(decoding: b, as: UTF8.self))
                    case .exitStatus(let s): exit = s
                    @unknown default: break
                    }
                    // 进度桥（懒总量）：total 取 rsync 自报 totalKnown 的 fileBytesTotal；
                    // 单文件条目 totalKnown 前用 totalHint（=item.size）兜底。都拿不到 → 0=不定量。
                    if let bp = byteProgress, parser.totalKnown {
                        bp(parser.fileBytesDone, parser.fileBytesTotal)
                    } else if let bp = byteProgress, let h = totalHint, h > 0 {
                        bp(min(parser.fileBytesDone, h), h)
                    }
                }
                if cancelled {
                    // 主动关通道已在 defer；rsync 中途退出=目标可能留半截（rsync 非
                    // --partial：自弃 .*.tmp 临时文件不留半截）。上抛取消不回退。
                    throw TCError.cancelled
                }
                let r = DirectRsync.classify(exitStatus: exit,
                                             stderr: String(decoding: stderrBuf, as: UTF8.self))
                switch r {
                case .ok:
                    self.lastCopyRoute = .directCrossHost   // 写在本(src)连接——见下方路由回传注
                    return .handled(bytesTransferred: parser.fileBytesDone)
                case .fail(let msg): throw TCError.unknown("rsync: \(msg)")
                case .relay(let reason):
                    self.lastCopyRoute = .relayed(reason)
                    return .unavailable(reason.diagnosticCode)
                }
            }
        } catch let e as TCError {
            if case .cancelled = e { throw e }   // 取消原样上抛不回退
            throw e
        }
    }
```

**路由回传（关键接线坑，实现前必读）**：`TransferEngine.fileProgress` 读的是
**目标**源的 `(dstSource as? SFTPSource)?.lastCopyRoute`（TransferEngine.swift:182），
但 `runDirectRsync` 跑在**源**连接上、route 写进了 src 的 lastCopyRoute → fileProgress
看不见。修法（实现者照做）：SFTPSource 加 internal `func mirrorRoute(_ r: CopyRoute)`
转发到内部 connection 的 `lastCopyRoute` setter（需把 `private(set)` 放宽为
`internal(set)` 或加 `func setRoute(_:)`）。接缝闭包（TransferEngine 内，同时握
ssrc/sdst）在 runDirectRsync 返回后把 **src 的 lastCopyRoute** 抄给 dst：
```swift
let out = try sftp.runDirectRsync(...)   // runDirectRsync 内部已写 ssrc.lastCopyRoute
sdst.mirrorRoute(ssrc.lastCopyRoute)     // handled 与 unavailable **两条都镜像**
return out                               // （回退路的黄点就靠这行——needsAuth 场景）
```
（抛错路不镜像——传输失败时面板走错误态，route 无意义。）
`RelayReason.diagnosticCode: String`（加在 SFTPClient.swift）：六 case 各回稳定英文码
（"needsAuth"/"rsyncMissing"/"execRejected"/"channelGone"/"cpMissing"/"unsupportedFlags"）
——仅作 `.unavailable(String)` 诊断透传，UI 文案走 route 枚举不走此串。route 真值经
`mirrorRoute` 传递，不走 String round-trip。

- [ ] **Step 3: SFTPSource 转发面**（SFTPSource.swift）

```swift
    /// 直传对端参数（连接记录只读投影；密码不在其中——直传只认密钥信任）。
    var peer: DirectRsync.Peer { DirectRsync.Peer(host: config.host, port: config.port, username: config.username) }
    /// 密码认证 → 直传先天不可用（不开 rsync）：needsAuth 由引擎侧判定，本方法只转发。
    var supportsDirectCross: Bool { if case .keyFile = config.auth { return true }; return false }
```

（`SFTPConnection` 需暴露 `var peer` 与 `runDirectRsync` 的 internal 转发；`SFTPSource`
内部 `_connection` 懒建逻辑复用。）

- [ ] **Step 4: TransferEngine 接线**（run() 内，byteProgress 定义之后、performCopy 之前）

```swift
            // 直传接缝：两端皆 SFTP + 不同服务器 + 源端 keyFile 认证（密码认证先天
            // 无信任）才可能；不满足直接 .unavailable 零开销（引擎 sticky，只问一次）。
            if let ssrc = srcSource as? SFTPSource, let sdst = dstSource as? SFTPSource,
               ssrc.sourceID != sdst.sourceID, ssrc.supportsDirectCross {
                engine.directCrossTransfer = { item, destDir, bp in
                    guard let sftp = srcSource as? SFTPSource else { return .unavailable("source not sftp") }
                    return try sftp.runDirectRsync(
                        // destDir = 全目标路径（接缝合同，Task 1 testSeamReceivesJoinedDest）
                        item: DirectRsync.ItemTarget(remotePath: item.path.pathString,
                                                     dstPath: destDir.pathString,
                                                     isDirectory: item.isDirectory),
                        peer: sftp.peer,
                        totalHint: item.isDirectory ? 0 : item.size,
                        byteProgress: bp, cancel: cancel)
                }
            }
```

（`engine` = `self.engine`（OperationEngine）——确认 TransferEngine 持有的 engine 实例
即执行 performCopy 的那个；`directCrossTransfer` 是 per-run 闭包，每次 run() 重赋值
防跨 run 泄漏旧源引用；cleanups 关闭时置 nil。）

**字节帧桥接锁**（`TransferPanelDirectRouteTests.swift`，新建）：用注入假
`directCrossTransfer` 的 engine + 假 SFTPSource 不可行（SFTPSource 非协议）→ 锁改打
接缝→byteProgress 的**数学**：Task 1 `testBytesDoneAccumulatesAcrossItems` 已锁累计；
本文件补 TransferEngine.ThrottleState 对 `total==0` 帧的行为锁（**实现注意**：既有
byteProgress 闭包 `bytesDone: done, bytesTotal: total` 直传 0——面板需把 bytesTotal==0
视为不定量；`TransferProgressWindowController.apply` 现有逻辑 `guard bytesTotal` 只挡
nil 不挡 0 → **改为 `guard let bt, bt > 0`**，此改动同时锁住）。

- [ ] **Step 5: 全量绿** Run: `swift test 2>&1 | tail -3`

- [ ] **Step 6: 变异证伪**：TransferEngine 里注释掉接缝注入 → Step 1 回退锁里
  「真实 exec 通道被触达」断言（stderrBuf 含 ssh 输出 / lastCopyRoute 曾为 needsAuth）
  红；恢复。

- [ ] **Step 7: Commit**

```bash
git add Sources/FlyCommander/Remote Tests/FlyCommanderTests/DirectConnectionProbeTests.swift Tests/FlyCommanderTests/TransferPanelDirectRouteTests.swift
git commit -m "feat(remote): server-to-server rsync exec + wire seam into TransferEngine"
```

---

## Task 5: XCUITest 假路由演示模式（FLY_UI_DEMO）

**Files:**
- Modify: `UITests/TransferProgressUITests.swift`（或既有 FLY_UI_DEMO 载体文件——
  `grep -rn "FLY_UI_DEMO" UITests Sources` 找现有 demo 注入形状，照其加新模式）
- Modify: 对应 app 侧 demo 注入点（Sources 里 FLY_UI_DEMO 读取处）

**Interfaces:**
- Consumes: Task 2 色点 + routeText、`TransferProgressWindowController.apply`
- Produces: 无（终端测试）

- [ ] **Step 1**: app 侧 demo 模式加 `direct` 分支：启动后直接把
  `TransferProgressInfo(name:"big.bin", fileDone:3, fileTotal:10, bytesDone:32_000_000,
  bytesTotal:100_000_000, route:.directCrossHost)` 连拍几帧（定时器 100ms 推进
  bytesDone）灌给面板，展示绿点 + 真字节进度 + 速度文案。
- [ ] **Step 2**: UITest：以 `FLY_UI_DEMO=direct` 启动 → 找到 "Transferring…" 窗口 →
  断言含 "Direct server-to-server"（英文 locale）与 "%"/"s" 速度字样；
  再拍一帧 `.relayed(.needsAuth)` 断言出现 "no key trust"。
- [ ] **Step 3**: 跑 UI 锁（遵守记忆规约：先杀残留实例、英文输入法）：
  `xcodegen generate && xcodebuild test -scheme FlyCommander -destination 'platform=macOS' -only-testing:FlyCommanderUITests/<新类> 2>&1 | tail -20`
  判绿读 `** TEST SUCCEEDED/FAILED **` 非 `$?`。
- [ ] **Step 4: Commit** `git commit -m "test(uitests): direct/relayed fake-route demo mode assertions"`

---

## Task 6: 全量回归 + 发布前验证

- [ ] `swift test` 全量：≥1005+新增、1 skip、0 fail。
- [ ] `xcodegen generate && xcodebuild test -scheme FlyCommander -destination 'platform=macOS'`
  全量 XCUITest（含新 Task 5；flaky 定性按记忆 uitest_runner_transient_flaky）。
- [ ] 用户真机冒烟清单：两台真 SFTP（有 A→B 信任）F5 目录 → 绿点+文件名+速度；
  无信任 → 黄点「双机免密信任未建立」+ 传输仍完成；源机 `which rsync` 无 →
  黄点「源服务器没有 rsync」。
- [ ] 若回归发现需修复项 → 独立 commit（最小修改），重跑全量确认绿。

---

## Spec 覆盖自检（写完后复查）

| Spec 条目 | 落地 Task |
|---|---|
| 接缝粒度=顶层条目、`.handled` 跳递归 | Task 1（`testDirectoryItemGoesWholeToSeam`） |
| 冲突语义对齐（overwrite 先删/目录合并不进 overwrite） | Task 1（`testOverwriteRemovesThenAsksSeam`/`testExistingDestDirSkipsSeam`） |
| move=直传后删源根 | Task 1（`testMoveHandledDeletesSource`/`testMoveDirectoryHandledDeletesSource`） |
| 整批粘连 | Task 1（`testUnavailableFallsBackAndStickyForBatch`） |
| 抛错不回退 | Task 1（`testThrowPropagatesNoFallback`）+ Task 4 |
| 密码绝不上命令行 | Task 3（Peer 无 auth 字段 + `testNoSecretInCommand`）+ 全局约束 2 |
| BatchMode 必在 | Task 3（命令构造锁） |
| needsAuth/rsyncMissing 分类 | Task 3（classify 锁）+ Task 2（文案） |
| `--progress` 而非 `--info` | Task 3 + 全局约束 1 |
| 懒总量字节进度+速度 | Task 3（解析器）+ Task 4（桥接）+ Task 5（UI 锁） |
| 绿点/黄点 | Task 2（`testDotColorThreeStates`） |
| 当前文件名 | Task 3 解析器 `fileName` + Task 4 桥接 |
| 取消=关 exec session | Task 4（`defer close` + cancel 分支） |
| 色点位置=传输面板 | Task 2 |
| XCUITest 假路由 | Task 5 |