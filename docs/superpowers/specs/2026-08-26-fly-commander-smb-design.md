# FlyCommander — Samba/SMB 远端后端设计

日期：2026-08-26

## 1. 背景与目标

FlyCommander 是键盘优先的双栏文件管理器。`FileSource` 协议是中心抽象——每个远端后端
= 一个新的 `FileSource` 实现，不为它另起一套浏览/传输/搜索/删除逻辑。SFTP 已按此模式落地
（`SFTPSource` 包裹 Traversio）。本设计加 **Samba/SMB** 后端，让远端能力从"仅 SSH"扩展到
"SSH + SMB"，覆盖 TrueNAS / Windows 共享等常见内网文件服务器。

**目标：**
- 用户可从 UI 连接一个 SMB share，它在窗格里像 SFTP 标签一样浏览、传输、搜索、删除。
- 复用既有能力：跨源传输、远端删除（无废纸篓+确认）、远端降级预览、**刚做的通用搜索**
  （`FileSearcher` 现按 `FileSource` 递归，SMB 免费获得）——不为 SMB 特判。

**非目标（本次不做）：**
- 多用户/多 share 并发之外的复杂共享语义（ACL、NTFS 流、快照浏览）。
- SMB 服务端搜索（本就没有；搜索走客户端逐目录列举，同 SFTP）。
- share 持久化自动重连（app 重启不自动挂；最近连接回填表单，用户手动重连）。

## 2. 关键洞察：挂载式后端，不是协议客户端

本机环境（已 probe）：
- **无 `smbclient`、无 Homebrew**（装不了 Samba 用户态客户端）。
- **有系统原生**：`/sbin/mount_smbfs`（挂载）、`smbutil view`（列 shares）、`/sbin/umount`
  （卸载；`unmount_smbfs` 缺失，用 `umount -f`）。
- 用户真实目标：`//shaogaoyang@truenas._smb._tcp.local/downloads` 挂在 `/Volumes/downloads`。

**核心简化：** 挂载后 SMB share 就是一个真实本地 POSIX 目录。因此 `SMBSource` 的
**全部 IO 委托给现成的 `LocalFileSource`**（同步、零 AppKit、零 async 桥接）。

对比 SFTP：`SFTPSource` 包 Traversio 的 async API，需要 `performSync` + NSLock +
DispatchSemaphore 那一套（reduced-SDK 下不能动态建队列）。SMB 完全不需要——挂载点就是
本地路径，`LocalFileSource` 直接读写。**复杂度集中在挂载生命周期 + 凭据安全，不在 IO。**

## 3. 路径模型：`smb://` scheme

`TCPath` 现在只特判 `sftp://` 前缀走"远端原样保留"，其它一律 `fileURLWithPath`（本地）。
加 `smb://` 到同一特判分支：

- scheme 形如：`smb://<server>/<share>/<relative...>`
  - 例 `smb://truenas/downloads/docs/a.txt`
  - server = `url.host`（可含 `.local` mDNS），share = path 首段，relative = 其余。
  - **不编码 user/password/port 进 URL**（SMB 用 445 默认端口；凭据不落 URL，见 §5）。
- `isRemote` 自然为 true（`url` 非 file URL）。
- `sourceID` = `"smb://<server>/<share>"`（同源判定：同 server+share 视为同一挂载点）。

`SMBSource` 持有 `mountPoint: URL`（挂载点本地路径）。路径转换：
```
toLocal(_ p: TCPath) -> URL:
    rel = p.pathString 去掉 "/<share>" 前缀后的相对段
    return mountPoint.appendingPathComponent(rel)   // rel 为空 → mountPoint 本身
```
返回的 `FileItem.path` 用 `TCPath("smb://\(server)/\(share)\(相对段)")`（mirror `SFTPSource.map`）。

**为何 sourceID 用 server+share 而非挂载点：** 挂载点路径（`/Volumes/FlyCommander/<hash>`）
是内部实现细节，会随重挂载变；server+share 是用户视角的稳定身份，与 SFTP 的
`sourceID = host:port` 语义一致。

## 4. 组件清单

全部新文件放在既有目录下，逐一 mirror SFTP 的对应物。

### 4.1 `TCPath`（改 `Sources/TCCore/Path/TCPath.swift`）
`init(_ string:)` 的特判从 `sftp://` 扩到 `sftp://` 或 `smb://`。一行改动。

### 4.2 `SMBSource: FileSource`（新 `Sources/FlyCommander/Remote/SMBSource.swift`）
```
public final class SMBSource: FileSource {
    let config: SMBConnectionConfig
    let mountPoint: URL          // 已挂载的本地根
    private let local = LocalFileSource()

    sourceID   = config.sourceID          // "smb://server/share"
    isRemote   = true
    supportsTransfer = true               // 挂载点=本地，全能力

    // 9 个 FileSource 方法各 ~2 行：
    listDirectory(p) = local.listDirectory(toLocal(p))   // 再把 FileItem.path 重映射回 smb://
    stat / isDirectory / copyItem / moveItem / renameItem /
    makeDirectory / removeItem / openReader / streamWrite  同理委托 local
    closeConnection() = unmount(mountPoint)               // 由调用方显式调
}
```
- `listDirectory`/`stat` 返回的 `FileItem`：委托 local 拿到本地 `FileItem` 后，把 `id` 与
  `path` 重映射为 `smb://`（mirror SFTP 的 `Self.map` 但更简单——只改 id/path，name/size/
  isDirectory/isHidden 等直接用 local 的值）。抽 `static func remap(_ item: FileItem,
  in: TCPath) -> FileItem` 纯函数可单测。
- **删除语义**：local.removeItem 递归删（`fm.removeItem`）。`isRemote=true` → 上层自动走
  "无废纸篓+确认" 路径（同 SFTP）。**注意**：挂载点上的删除直接删远端文件，无本地回收站
  兜底——这是 SMB 远端的既定语义，确认弹窗已覆盖。
- **错误映射**：local 已把 POSIX 错误转成 TCError（`asTCError`）。SMB 挂载点上权限/不存在
  等错误与本地一致；`closeConnection`（unmount）失败单独包成 TCError。

### 4.3 `SMBConnectionConfig` / `SMBConnectionRecord`（新，或并入 `SMBSource.swift`/`ConnectionStore`）
mirror `SFTPConnectionConfig`/`SFTPConnectionRecord`：
```
SMBConnectionRecord（可编码，UserDefaults 存，不含密码）:
    server: String       // "truenas._smb._tcp.local" 或 IP
    share: String        // "downloads"
    domain: String?      // 可选
    username: String
    remembers: Bool
    var credentialAccount: String { "server|domain|share|username" }   // Keychain account
    var sourceID: String { "smb://\(server)/\(share)" }
```
（无 port、无 auth kind——SMB 只有用户/密码/域。）

### 4.4 `SMBMountManager`（新 `Sources/FlyCommander/Remote/SMBMountManager.swift`）— SMB 特有心智
```
final class SMBMountManager {
    /// 挂载 share 到 /Volumes/FlyCommander/<sanitized-server-share>，返回挂载点 URL。
    /// 已挂载（mount 表查得到该 sourceID 的卷）→ 复用，不重复挂。
    func mount(config: SMBConnectionConfig, secret: String?) throws -> URL
    func unmount(_ mountPoint: URL) throws
    func isMounted(_ mountPoint: URL) -> Bool
    /// 启动时清理本 app 上次残留的 /Volumes/FlyCommander/* 挂载（用户手动挂的 /Volumes 下
    /// 其它 smb 卷不碰）。
    func reclaimStale()
}
```
- **挂载点命名**：`/Volumes/FlyCommander/` + 把 `server/share` 里的非法字符替换成 `-`
  （如 `truenas._smb._tcp.local--downloads`）。可预测、可 reclaim、可 `mount` 表反查。
- **跑 mount**：`Process` 调 `/sbin/mount_smbfs`。参数见 §5 凭据。用 `FileHandle` 捕获
  stderr 诊断（失败时给 TCError 带 stderr 摘要，同 `SFTPServerFixture` 打日志的做法）。
- **卸载**：`/sbin/umount -f <mountPoint>`（`-f` 容忍短暂 busy）。
- **reclaimStale**：启动时 `mount` 命令解析出 `/Volumes/FlyCommander/*` 的 smbfs 卷全部
  umount。幂等、静默（无残留可回收时 no-op）。

### 4.5 `SMBConnectionStore`（新，mirror `ConnectionStore`）
```
final class SMBConnectionStore {
    static let shared
    var sources: [String: SMBSource]       // sourceID → source
    var recent: [SMBConnectionRecord]      // UserDefaults "smb.recentConnections"
    let credentials: SMBCredentialsStore   // Keychain service "FlyCommander.smb"
    func connect(_ request: SMBConnectionRequest) throws -> (SMBSource, home: TCPath)
    func disconnect(_ id: String)          // unmount + 移除
    func disconnectAll()
    ...
}
```
`connect`：复用已挂的同 sourceID → 直接返回；否则 `SMBMountManager.mount` 拿挂载点 →
建 `SMBSource` → 存表 → 按 remember 存/删 Keychain → 记最近连接。**同步阻塞**（mount 可达
数秒）→ 必须非主线程调（mirror `ConnectionViewController` 的后台队列模式）。

### 4.6 `SMBCredentialsStore`（新，mirror `CredentialsStore`）
`KeychainCredentialsStore(service: "FlyCommander.smb")`——**独立 service**，与 SFTP 的
`"FlyCommander.sftp"` 不串。account = `credentialAccount`（server|domain|share|username）。
存密码。

### 4.7 `SMBConnectionViewController`（新，mirror `ConnectionViewController`）
表单字段：服务器 / 共享 / 域（可选，折叠或单行）/ 用户 / 密码 / 记住密码 / 状态 / 连接/取消。
比 SFTP 少 port 与密钥文件/passphrase 两段。`prepare()` 回填最近连接 + 已记密码。
**可选增强**（若成本低）："浏览共享" 按钮跑 `smbutil view //server` 列 shares 供选——
列为 P2 可加，MVP 手动输 share 名即可。

### 4.8 接线（改 `MainMenu.swift` / `MainViewController.swift` / `InternalCommandExecutor.swift`）
- **菜单**：文件菜单加 "SMB 连接…"（`menuSMBConnect(_:)`），与 "SFTP 连接…" 并列。
- **MainViewController**：`beginSMBConnection()` → 建 `SMBConnectionWindowController` →
  `onConnected { source, home in 开新标签（同 beginConnection 的 onConnected，pane 接到
  SMBSource，startPath = home）}`。
- **命令栏**：`smb server[/share] [user]` 内部命令 → 预填 `SMBConnectionViewController`
  （mirror `sftp host[:port]` 的 prefill 钩子）。

## 5. 凭据传递（关键权衡，如实记录）

macOS `mount_smbfs` 的**唯一非交互凭据路径**是 URL 形式
`//domain;user:pass@server/share`（man 确认无 Samba 的 `credentials=` 文件选项）。

- 用 `Process.arguments` 传 → **密码会短暂出现在进程参数里**（本机 `ps -ef` 同用户可见，
  时长 = mount 握手期间，通常亚秒到数秒）。
- **缓解**（选做，视实现成本）：密码含 `&`, `;`, `@`, 空格等特殊字符时 URL 需 percent-
  encoding；SMB 域分隔用 `;`（`domain;user`）。对常见用户名/密码无特殊字符的场景直接拼。
- **取舍说明**：这是挂载式后端的固有代价（用户态无 SMB 客户端、无 lib 可调），本机已挂载的
  TrueNAS 卷同样经此路径。对"个人本地工具、不对外分发"的定位可接受；**记录为已知限制**，
  不宣称"密码绝不落进程表"。若将来要更严，可选 `NSFilePresenter`/`SecItem` 之外的路径再评估。
- **记住密码** 走 Keychain（`FlyCommander.smb`），**不落** UserDefaults（recent 记录
  `remembers` 布尔但只存账号标识，不含密码）——与 SFTP 完全一致。

## 6. 复用（不为 SMB 另起一套）

- **搜索**：`FileSearcher.search(root:source:)` 现按 `FileSource.listDirectory` 递归 →
  传 `SMBSource` 即可，SMB 搜索零新代码。
- **跨源传输**：`CommandRouter.handleTransfer` 见任一端 `isRemote` → `TransferEngine` 后台
  流式（SMB 端 `supportsTransfer=true`，读/写全走挂载点本地路径）。
- **远端删除**：`isRemote` → "无废纸篓 + 确认" 弹窗（同 SFTP）。
- **降级预览**：`isRemote` → 现有远端降级逻辑（同 SFTP）。
- **图标**：远端文件按 `item.path.isRemote` 走 `UTType` 图标（刚做的特性，自动生效）。
- **导航/聚焦/标签**：`FilePane`/`Workspace`/`TabGroup` 全按 `FileSource` 抽象，零改动。

## 7. 线程与 reduced-SDK 约束

- **不动态建 `DispatchQueue`**（reduced-SDK SIGSEGV 模式）。连接走 `DispatchQueue.global`
  （系统预建，安全）——mirror `ConnectionViewController.connectTapped`。
- `SMBSource` 内无队列、无 async（local 同步 IO）。`mount`/`umount` 用 `Process.run` +
  `waitUntilExit`（同步，在后台队列上调用）。
- 挂载点本地 IO 由 AppKit 层照常走 `FilePane.loadAsync` 后台队列（远端窗格既有模式）。

## 8. 测试策略（用户已选：纯逻辑单测 + TrueNAS e2e 门控）

本机无 `smbclient`/`brew`，**起不了本地 SMB 服务器**，唯一真实目标是用户的 TrueNAS。

**Tier 1 — 纯逻辑单测（CI 无服务器也绿，`swift test`）：**
- `TCPath` `smb://` 解析：`isRemote`、`sourceID`、server/share 拆分、`pathString`。
- `SMBSource.remap`：本地 `FileItem` → `smb://` id/path 重映射（含子目录相对段、根项）。
- 路径映射 `toLocal`：`smb://server/share/a/b.txt` ↔ `mountPoint/a/b.txt`（用 `file://`
  假挂载点纯算，不真挂）。
- `SMBConnectionConfig.sourceID` / `credentialAccount` 稳定性（重排/特殊字符）。
- `SMBMountManager` 的 **mount 命令行拼装**抽纯函数：给定 config+secret → 期望的
  `[mount_smbfs, URL, mountPoint]`（不真跑 Process，纯验证参数）；含 percent-encoding
  分支、域分隔 `;`。
- `SMBConnectionStore`：活动连接复用（同 sourceID 返回同一 source）、最近连接置顶去重
  （UserDefaults 注入独立 suite，不碰 .standard）——mirror SFTP 的 store 单测。
- `SMBCredentialsStore`：`KeychainLike` 注入 fake，存/取/删 + service 隔离。

**Tier 2 — TrueNAS e2e（门控，默认 skip）：**
- 新 `Tests/FlyCommanderTests/RemoteSMBE2ETests.swift`。读 env
  `FLY_SMB_TEST_SERVER` / `FLY_SMB_TEST_SHARE` / `FLY_SMB_TEST_USER` / `FLY_SMB_TEST_PASS`。
  四者齐备才跑，否则 `XCTSkip("未配置 FLY_SMB_TEST_* 环境变量")`。
- 用例：`SMBMountManager.mount` → `SMBSource.listDirectory(home)` 非空断言 →
  建子目录 `mkdir` → 写小文件（streamWrite）→ list 验证存在+大小 → `removeItem` 删
  → 断言消失 → `disconnect`（unmount）→ 断言挂载点已不在。
- **清理**：teardown 必 unmount + 删临时文件，不污染真 NAS。

**手工冒烟（验证节）：** 连真实 TrueNAS share，浏览/搜索/跨源传输/删除/退出残留回收各点一遍。

## 9. 交付边界与 carry-forward

**本次做：** §4 全部组件 + §6 复用接线 + Tier 1 单测 + 门控 e2e。

**Carry-forward（本次不做，记录备查）：**
- `smbutil view` 自动列 shares 的"浏览共享"UI（MVP 手动输 share 名）。
- 密码 percent-encoding 的完整 RFC3986 处理（MVP 处理常见字符集；罕见特殊字符密码的边角
  留待真机碰到时补）。
- app 退出时的优雅 unmount（当前靠下次启动 `reclaimStale` 回收；若要"退出即卸"需接
  `applicationWillTerminate`，可作小改进）。
- 已挂载卷在 Finder 侧栏可见（`/Volumes/FlyCommander/*`）——选定 `/Volumes` 的固有代价，
  换挂载点私有目录才隐藏（曾作为备选，用户选 /Volumes 求稳）。

## 10. 验证

1. **Tier 1 全绿**：`swift test`（含新 SMB 纯逻辑单测 + 既有全量不回归）。
2. **门控 e2e**：`FLY_SMB_TEST_SERVER=... FLY_SMB_TEST_SHARE=... FLY_SMB_TEST_USER=... FLY_SMB_TEST_PASS=... swift test --filter RemoteSMBE2E` —— 对真 NAS 跑通挂载/列举/写/删/卸载。
3. **UI 回归**：`xcodegen generate && xcodebuild test -scheme FlyCommander -destination 'platform=macOS'` —— 既有 29 条不回归（新增菜单项不破坏既有 AX 断言）。
4. **手工冒烟**：`swift run FlyCommander`，文件菜单"SMB 连接…"连 TrueNAS，验证 §8 冒烟各点。
5. **残留回收**：连接后 `kill` app 再重启，确认 `/Volumes/FlyCommander/*` 被 `reclaimStale` 清掉。
