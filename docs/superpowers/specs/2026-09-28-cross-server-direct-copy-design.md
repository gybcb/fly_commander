# 跨 SFTP 服务器双机直传（Direct Server-to-Server Copy）设计

日期：2026-09-28
状态：已与用户逐节确认

## 目标

F5/F6 在**两端都是 SFTP、且是不同服务器**时，让字节**不经过本机**：在源服务器上
执行 `rsync` 把它自己的文件推到目标服务器。做不到（服务器之间没有免密信任、exec
被禁等）就**自动回退**现有的本机中转 pump，用户无感。传输面板用色点显示实际走了
哪条路：绿=字节不出服务器，黄=本机中转。

非目标：密码代传（sshpass）、rsync 增量、本机作 SSH 跳板桥、预探测、
SMB/FTP 参与的混合直传、直传字节级速度。

## 决策记录（用户拍板）

1. 通道形态 = **源机 exec rsync**（不是填目标密码、不是本机跳板）。
2. 进度 = **rsync `--info=progress2` 流式截获** → 真实字节进度 + 速度（与 pump 同规格）。
3. 目录 = **一条 `rsync -a` 扫整棵子树**（不逐文件往返）。
4. 色点位置 = **传输面板**（沿用现有 routeLabel 行），不做主窗工具栏预判。
5. 范围 = **复制 + 移动**，两者对称（move = rsync 成功后源端删除）。
6. 源机无 rsync / rsync 报错 → **直接回退本机中转 pump**（不为直传再造第二条
   scp 通道；保持最小实现面）。

（第 2、3 条 2026-09-28 二轮修订：初版为"逐文件 scp + 不定量进度条"，用户改为
"目录 scp -r + 截输出看文件与速度"，落地形态即本条 rsync 方案。）

## 核心约束（为什么"直传"必须建立在服务器间信任上）

SSH/SFTP 协议没有"让第三方把 A 的文件转给 B"的中立通道。要让字节绕开本机，
唯一办法是让 **A 机器自己发起对 B 的连接**——A 上必须已存在能登录 B 的密钥。
这是协议决定的，不是实现选择。该信任不存在时 rsync 会要求口令认证 →
`-oBatchMode=yes` 令其立即失败而不挂起 → 我们据此回退本机中转。
"需要认证就退到现在的模式"= 这一条的 UI 后果。

### 为什么是 rsync 而不是 scp（已核实 Traversio 源码 + scp 行为）

- `SSHConnection.execute` **只能开纯 exec session，没有 pty**
  （pty 只在 `openShellSession(pseudoTerminalRequest:)` 上）。`scp` 只在 stderr
  接 tty 时才打印进度行，无 tty 时完全静默 → "exec scp + 截输出"截不到任何东西。
  `rsync --info=progress2` 把进度写 stderr 且**不依赖 tty** → exec 通道可直接流式截。
- `scp -r src dst/` 在 dst 已存在同名目录时**嵌一层**（`dst/src/…`），与既有多轮
  拍板的**合并语义**（目标目录存在则内容合并、绝不嵌套）冲突。`rsync -a` 天然是
  合并语义，冲突消失。

## 设计

### 1. 接缝：TCCore 注入闭包（粒度 = 顶层条目）

一条 rsync 扫完整棵子树 → 引擎必须**跳过自己的逐文件递归**。故接缝粒度上提到
**每个顶层条目**（一个普通文件，或一棵目录树）：

```swift
public enum DirectOutcome: Equatable {
    case handled(bytesTransferred: Int64)   // 整条已完成
    case unavailable(String)                // 直传不可用（原因串），调用方走 pump
}

public var directCrossTransfer: (
    _ item: FileItem,
    _ destDir: TCPath,
    _ byteProgress: ((Int64, Int64) -> Void)?   // (本条目已传, 本条目总量)
) throws -> DirectOutcome
```

- 调用点：跨源分支里**逐顶层条目**处（现 performCopy/performMove 的 per-item 循环，
  在 `resolveConflict` 之后）。`.handled` → 跳过 `stream(...)` / `copyDirectoryCross`
  整段；`.unavailable` → 走原 pump/pump 递归，**整批粘连**（首次不可用后置标记，
  同批后续条目不再尝试）。
- 冲突语义对齐：单条目"覆盖"决策已由 `resolveConflict` 在调用前处理（覆盖=先
  `removeItem(dst)`，故 rsync 面对的要么不存在要么是要合并的目录）；目录内部一律
  合并——与 `copyDirectoryCross` 现行"绝不进 overwrite 分支"逐字同语义。
- 移动：rsync 成功后由 performMove 现有逻辑删源根一次（与跨源 pump 路同）。
- 接缝契约：后台线程调用；抛错 = 传输失败（不回退，与 pump 抛错同语义）；
  `byteProgress` 由实现方节流上报（复用 `TransferEngine.progressThrottleInterval`）。

### 2. App 层实现：源机 exec rsync

`TransferEngine` 接线到接缝。启用条件：两端 `sourceID` 都以 `sftp://` 开头**且不相等**
（同源仍走现有 `cp -a` 路，不经此接缝）。

目标串从 B 的连接参数取 `user@host[:port]`。**密码绝不进入命令行**——直传只认
A→B 密钥信任；B 需要口令 = 直传不可用（`-oBatchMode=yes` 保证立即失败不挂起）。

在 A 上 exec（目录条目，源尾斜杠=拷内容不嵌套）：

```
rsync -a --info=name,progress2 -e "ssh -oBatchMode=yes -p <port>" <src[/]> user@B:<dst/>
```

- 普通文件不带尾斜杠；目录条目 src/dst 都带尾斜杠。
- `-a` = 递归+保留权限/时间戳/符号链接，与同源 `cp -a` 保真基准一致。
- 路径引用复用 `ServerSideCopy.shellQuote`；`-e` 串内 ssh 参数不含用户输入路径，
  仅 host/port（来自连接记录），注入面同 shellQuote 一并覆盖。
- `--info=name,progress2` = 当前文件名行 + 整体进度行；解析器容忍 `\r` 与字段
  宽度变化，**解析失败降级为"无字节进度"**（仍算直传成功，绝不因解析失败判传输失败）。

失败分类（复用 `RelayReason` 形状，新增 case）：
- `needsAuth` — 非零 + stderr 命中 `Permission denied` / `Host key verification
  failed` / `Connection refused` / `Could not resolve hostname` 等 → `.unavailable`。
- `rsyncMissing` — exit 127（源机无 rsync）→ `.unavailable`。
- `execRejected` / `channelGone` — 沿用现有 exec 通道级判定。
- 其余非零（含 `--info=progress2` 不被 rsync 2.x 识别的 usage 报错）= **命令级失败**
  → 带 stderr **抛错不回退**，与同源 `cp` 现行政策逐字一致。（注：老 rsync 缺
  progress2 属"服务器太旧"，给用户清晰诊断优于静默降级到无进度直传。）
- 首次成功顺带确认 exec 通道与信任可用，无需预探测。

`sourceID` → 连接参数（host/port/user）需要查询面；取现有 `SFTPSource` 已有信息，
缺字段则加**只读** getter（不改 FileSource 协议）。

### 3. 传输面板：色点 + 真字节进度

`CopyRoute` 加 case `directCrossHost`。

- 绿点（8pt 圆点，`routeLabel` 前）= `.serverSide` 或 `.directCrossHost`。
- 黄点 = `.relayed(reason)`；`needsAuth` 措辞 = "双机免密信任未建立，已改本机中转"，
  `rsyncMissing` = "源服务器无 rsync，已改本机中转"。
- 直传路 **有真字节进度**：接缝的 `byteProgress` 桥到引擎既有 byteProgress 通道
  （`bytesDone = 已完成条目累计 + rsync 已传`，`bytesTotal = 条目总量`）→ 面板
  走既有 determinate 分支 + `TransferSpeed.estimate`。多条目批次 = 逐条目推进，
  与跨源 pump 现有观感一致。
- **速度语义如实**：rsync 报的是 A↔B 直传速率（不是本机链路），面板不区分标注；
  当前文件名取 `--info=name` 行（比 pump 只知道"正在写哪个目标"更准）。
- 取消：关闭 exec session → A 上 rsync 收 SIGHUP 退，其 ssh 子进程随之退；rsync
  默认非 `--partial`，中断的传输文件自弃不留半截。不加 `pkill`。

### 4. 测试

- **TCCore 接缝锁**（fake source，无网络）：`.handled` 不触 reader/writer 且条目级
  完成照常上报；`.unavailable` 走 pump 且带 reason；目录条目整棵交接缝（引擎不再
  递归）；move 直传后仍删源；首条目 `.unavailable` 后同批不再问（粘连）；接缝抛错
  上抛不回退；`byteProgress` 桥接累计值单调不减。
- **App 纯函数锁**：rsync 命令行构造（BatchMode 必在、`-p` 端口、目录尾斜杠规则、
  shellQuote、user@host 拼装）；stderr → RelayReason 分类表（含 needsAuth 各串）；
  **progress2 解析器**（真实样例串 / `\r` 抖动 / 字段缺失 → nil / 乱码 → nil 不抛）。
- **e2e**：双 `SFTPServerFixture`（上轮双 sshd 夹具先例）。主锁 = 跨服务器目录复制
  全路走 `.handled` 且目标树逐文件字节+权限一致；副锁 = 无信任时精确回退黄路
  （`lastCopyRoute == .relayed(.needsAuth)`）。**注**：sshd 夹具环境里 A 能否 exec
  出真 rsync、以及 A 连 B 的信任注入（A 账户 authorized_keys 塞 B host key + 客户端
  key），实现期先做一次可行性 spike，不通则 e2e 降级为"接缝 fake + 面板锁"。
- **面板锁**：`apply(route:)` 三态色点/文案（真窗 Tier-1 先例）。
- **XCUITest**：`FLY_UI_DEMO` 增直传假路由模式，断言绿点在位 + 字节进度 + 速度文案。
- **变异证伪**：接缝恒 `.unavailable` → handled 锁红；粘连判定反 → 不再问锁红；
  BatchMode 漏 → 命令构造锁红；解析器把失败判成功 → 解析锁红。

## 风险与已知代价

- 直传要求 A→B 免密信任——**多数环境不具备**，故绿点是例外、黄点是常态。UI 文案
  须让用户明白这点，不承诺"自动打通"。
- rsync 依赖**源机有 rsync 二进制**（exit 127 分类回退已覆盖）；目标机 rsync 由
  rsync 协议自动拉起（A 通过 ssh 在 B 上 exec rsync），同样依赖 B 有 rsync——
  失败会以命令级错误出现，用户看到诊断后自行决定。
- 一条 rsync 一次 exec 往返扫整棵子树 = 已拍板形态（初版逐文件方案的 exec 建通道
  开销顾虑随之消失）；代价是条目内不再有文件级完成上报，面板"第 i/N 个文件"在
  单条目目录传输期间不推进（字节进度条照常推进，可接受）。
