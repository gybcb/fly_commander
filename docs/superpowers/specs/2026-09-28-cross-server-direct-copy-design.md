# 跨 SFTP 服务器双机直传（Direct Server-to-Server Copy）设计

日期：2026-09-28
状态：已与用户逐节确认

## 目标

F5/F6 在**两端都是 SFTP、且是不同服务器**时，让字节**不经过本机**：在源服务器上
执行 `scp` 把它自己的文件推到目标服务器。做不到（服务器之间没有免密信任、exec
被禁等）就**自动回退**现有的本机中转 pump，用户无感。传输面板用色点显示实际走了
哪条路：绿=字节不出服务器，黄=本机中转。

非目标：密码代传（sshpass）、rsync 增量、本机作 SSH 跳板桥、预探测、
SMB/FTP 参与的混合直传、直传字节级速度。

## 决策记录（用户拍板）

1. 通道形态 = **源机 exec scp**（不是填目标密码、不是本机跳板）。
2. 直传进度 = **文件粒度 + 不定量进度条**（不报字节、不算速度）。
3. 色点位置 = **传输面板**（沿用现有 routeLabel 行），不做主窗工具栏预判。
4. 范围 = **复制 + 移动，含目录**；目录由引擎逐文件递归，每个文件一次 scp。

## 核心约束（为什么"直传"必须建立在服务器间信任上）

SSH/SFTP 协议没有"让第三方把 A 的文件转给 B"的中立通道。要让字节绕开本机，
唯一办法是让 **A 机器自己发起对 B 的连接**——A 上必须已存在能登录 B 的密钥。
这是协议决定的，不是实现选择。该信任不存在时 scp 会要求口令认证 →
`-oBatchMode=yes` 令其立即失败而不挂起 → 我们据此回退本机中转。
"需要认证就退到现在的模式"= 这一条的 UI 后果。

## 设计

### 1. 接缝：TCCore 注入闭包

`OperationEngine` 新增注入属性（仿 `warnFormatter` 先例，保持 TCCore 零 AppKit）：

```swift
public enum DirectOutcome: Equatable {
    case handled                    // 已完成该文件搬运
    case unavailable(String)        // 直传不可用（原因串），调用方应走 pump
}

public var directCrossCopy: ((_ item: FileItem, _ dst: TCPath) throws -> DirectOutcome)?
```

- 调用点：跨源分支里**单文件字节搬运**处（现 `stream(from:to:...)` 被调的位置），
  即逐文件循环内、`copyDirectoryCross` 复用它。
- `.handled` → 跳过 `openReader`/`streamWrite`，但**照常上报文件级完成**。
- `.unavailable(reason)` → 记录 reason，走原 pump；**整批粘连**：首次拿到
  `.unavailable` 后置标记，同批后续文件不再尝试、不再回调。
- 冲突解决（`resolveConflict` / 目录合并语义 / 覆盖前 `removeItem`）、目录
  递归遍历、`mkdir`、移动删源（`srcSource.removeItem`）**全部不变**——接缝只
  替换"这个文件的字节怎么过去"。

接缝契约：闭包在后台线程调用；抛错 = 传输失败（不回退，与 pump 抛错同语义）。

### 2. App 层实现：在源机上 exec scp

`TransferEngine` 接线到接缝。启用条件：两端 `sourceID` 都以 `sftp://` 开头**且不相等**
（同源仍走现有 `cp -a` 路，不经此接缝）。

目标串从 B 的连接参数取 `user@host[:port]`。**密码绝不进入命令行**——直传只认
A→B 密钥信任；B 需要口令 = 直传不可用。

在 A 上 `execute`：

```
scp -p -oBatchMode=yes [-P <port>] <A 上绝对路径> user@B:<B 上绝对路径>
```

（`-p` 保留权限/时间戳，对齐同源 `cp -a` 的保真度基准；scp 默认不保，必须显式。）

- 路径引用复用 `ServerSideCopy.shellQuote`（POSIX 单引号，封死注入）。
- 失败分类复用 `RelayReason` 形状，新增一 case：
  - `needsAuth` — 非零退出 + stderr 命中 `Permission denied` /
    `Host key verification failed` / `Connection refused` /
    `Could not resolve hostname` 等：A 无到 B 的信任 → `.unavailable`。
  - `execRejected` / `channelGone` — 沿用现有判定（exec 通道级失败）。
  - `scpMissing`（exit 127）— 源机无 scp 二进制 → `.unavailable`。
  - 其余非零退出 = **scp 命令级失败**（权限/磁盘满）→ 带 stderr **抛错不回退**，
    与同源 `cp` 现行政策逐字一致。
- `-oBatchMode=yes` 是**永不挂起**的保证：无 TTY 时任何口令请求立即失败。
- 首次成功的 scp 顺带确认 exec 通道可用，无需预探测。

`sourceID` → 连接参数（host/port/user）需要一条查询面；取现有 `SFTPSource` 上
已有信息，若缺 user/host 字段则加**只读** getter（不改协议）。

### 3. 传输面板：色点 + 不定量进度

`CopyRoute` 加 case `directCrossHost`。

- 绿点（8pt 圆点，`routeLabel` 前）= `.serverSide` 或 `.directCrossHost`。
- 黄点 = `.relayed(reason)`，原因文案新 L10n 键，`needsAuth` 措辞为
  "双机免密信任未建立，已改本机中转"。
- 直传路 `bytesDone/bytesTotal = nil` → 面板既有"字节未知"分支自动出
  **不定量进度条**；补**已用时长**计时 + "第 i / N 个文件"（文件级上报本就有）。
  直传路不显示字节速度。
- 取消：关闭 exec 通道 → A 上 scp 写断管自亡（秒级）。不加 `pkill`。

### 4. 语义分叉（有意，与现有同源分叉同性质）

- 跨机直传（scp）：保留权限/时间戳/符号链接（scp -p 默认不含，
  实际取 `-p`；见实现任务）。
- 本机中转 pump：不保留。
两路都写 `lastCopyRoute`，UI 如实显示。

## 测试

- **TCCore 接缝锁**（fake source，无网络）：`.handled` 不触 reader/writer 且上报
  完成；`.unavailable` 走 pump 且带 reason；目录逐文件都经接缝；move 直传后仍删源；
  首文件 `.unavailable` 后同批不再问（粘连）；接缝抛错上抛不回退。
- **App 纯函数锁**：scp 命令行构造（BatchMode 必在、`-P` 端口、shellQuote、
  user@host 拼装）；stderr → RelayReason 分类表（含 needsAuth 各匹配串）。
- **e2e**：双 `SFTPServerFixture`（上轮双 sshd 夹具先例）；主锁 = 跨服务器目录
  复制全路走 `.handled` 且目标树逐文件字节一致；副锁 = 无信任时精确回退黄路
  （`lastCopyRoute == .relayed(.needsAuth)`）。
- **面板锁**：`apply(route:)` 三态色点/文案（真窗 Tier-1 先例）。
- **XCUITest**：`FLY_UI_DEMO` 增直传假路由模式，断言绿点在位 + 不定量条 +
  文件粒度文案。
- **变异证伪**：接缝恒 `.unavailable` → handled 锁红；粘连判定反 → 不再问锁红；
  BatchMode 漏 → 纯函数锁红。

## 风险与已知代价

- 直传要求 A→B 免密信任——**多数环境不具备**，故绿点是例外、黄点是常态。UI 文案
  须让用户明白这点，不承诺"自动打通"。
- 每文件一次 exec 往返：小文件海量目录时 exec 建通道开销可能高于单条 `scp -r`
  一次扫完。取舍=保冲突/合并/进度语义统一（已拍板逐文件）。若实测明显慢，
  后续可加"整目录一条 scp -r"快路径作为独立优化项。
- scp 是 exec 调用，依赖源机有 scp 二进制（127 分类已覆盖回退）。
