# 目录外部变更自动刷新（FSEvents）+ 手动刷新 ⌃R — 设计定档

日期：2026-09-10 · 分支基线：026056a（v0.0.3）

## 问题与裁决

外部进程增删改文件后，正显示该目录的文件列表不自动刷新。保焦点重载链早已完备
（`FilePane.load(preserveFocus:true)` → 无条件 `onReload` → `MainViewController.refresh`），
缺的只是**事件源**（全仓 FSEvents/DispatchSource/Timer 零命中）。

用户裁决（AskUserQuestion 2026-09）：
1. 覆盖**所有打开标签**（含后台标签）；
2. **SFTP 不自动轮询**（网络 RTT 失礼），手动 ⌃R 兜底；SMB v1 同样排除
   （pane.path 是 `smb://` scheme 非 fileURL，判据天然排除；纳入留 follow-up：
   经 `SMBSource.toLocal` 映射挂载点挂流且回调必须走 `loadAsync`）；
3. 手动入口 = **⌃R + View 菜单「Refresh」项**（⌘R 已被重命名占用）。

## Spike 定档（实测，写进 DirectoryWatchCoordinator.swift 注释）

**S1/S1b（FSEvents 运行时 + 首回调语义）**：本缩减 SDK 下 FSEvents 运行时全链可用，
主干定档 FSEvents，无需退 DispatchSource。
- 签名偏差两处：`FSEventStreamCreate` 的 sinceEvent 形参暴露为 `FSEventStreamEventId`
  （UInt64）非文档的 CFAbsoluteTime；返回 `FSEventStreamRef?`（可选）需解包。
- `kFSEventStreamEventIdSinceNow` 挂流**零历史回放** → 不需要「丢弃首组」逻辑。
- 实测 flag：外部 create=`0x11800`、delete=`0x11a00`；原子写额外冒 `.sb-*` 临时文件
  事件（同父目录，去抖合并后仍刷一次，无害）。
- Stop→Invalidate→Release 后零回调（销毁干净）。
- 监听目录自身被删 → 收到含该目录路径的事件 → 刷一次吃 `load()` 错误路（空列表，接受）。

**S2（⌃R 键路）**：菜单 keyEquivalent 路判绿（真窗 typeKey("r",.control) 无 crash、
不误触 ⌘R 重命名）。单路不双注（防双触发）；KeyDispatcher 不加 case 15。UI 层的
「按下生效」只能弱锁（真实效果与 FSEvents 自动刷新不可分离观测），强锁在
MainMenuTests 的键位值断言（"r" + [.control]，且 ⌘R 仍是重命名）。

## 结构

```
pane.load() 尾 ──onReload──► MainViewController.refresh(p)
                          └─► DirectoryWatchCoordinator.noteReloaded(p)   ← 单挂点三合一
FSEvents C 回调（utility 队列）──装箱──main.async──► handleEvents → 路径过滤 → 去抖 0.3s
                                                   └─► pane.load(preserveFocus:true) →（回 onReload，同路径 no-op 不成环）
didBecomeActive ──► refreshAllWatched()（只刷已注册流，兜 overflow 丢事件）
closeTab        ──► stopWatching(removed)（注销 + 取消挂起去抖项）
```

- **接缝协议化**：`DirectoryEventSource { start(); stop() }` +
  `DirectoryEventSourceFactory { makeSource(path:onEvent:) }`（onEvent 契约=主线程回调）。
  测试注入假工厂，真 FSEvents 语义由 XCUITest 跨进程覆盖。
- **C 回调零捕获**：`FSEventStreamContext.info = Unmanaged.passUnretained(source)`；
  回调线程只 NSLock 装箱 + `DispatchQueue.main.async` 整批投递，零触碰模型。
  `FSEventsDirectorySource.deinit stop()` 作野指针保险丝。
- **生命周期单挂点 = pane.onReload**：navigate/setSource/断连回退/操作后刷新的终点
  必是 load→onReload。同路径 no-op；变路径 stop 旧+start 新；非 fileURL → 注销。
- **判据 = `pane.path.url.isFileURL`**（不用 `source.isRemote`）：SFTP/SMB 的 path 是
  scheme 串，天然排除——用户裁决②由结构保证而非散点 if。
- **去抖**：内核 latency 0.5s 之上再并应用级 0.3s 尾沿窗（`DispatchWorkItem` +
  `main.asyncAfter`，PaneTableView.typeAhead 同范式）。pending 期吞后续事件。
- **主线程串行不变量**（删掉了一版 dirty 尾刷死代码）：只盯 fileURL 目录、本地 load
  在 main 同步执行、事件也投 main →「reload 执行中事件插队」结构上不存在。
- **路径过滤**：FileEvents 下深层子目录变更不影响浅层列表——仅事件项住在本目录
  （或其自身，删目录路）才刷；`MustScanSubDirs/UserDropped/KernelDropped/
  EventIdsWrapped/RootChanged` 无条件刷。

## 关键坑（实测）

1. **URL == 携带活文件系统语义**（本轮新坑）：目录在世时构造的 URL 与删后同路径构造的
   URL，`.path` 串相等但 `==` 为 false（absoluteString 尾斜杠 = 目录/文件语义翻转）。
   「目录被删 → load 错误路 → onReload → noteReloaded 同路径 no-op」这条生产路会因
   `==` 永假而**重挂流永不停**。注册与比较一律改用 **`.path` 串**。
2. **临时目录符号链接域**：`NSTemporaryDirectory()`=/var/…，FSEvents 交付解析后真实
   路径 /private/var/… → `comparable()`（resolvingSymlinksInPath + standardizedFileURL）
   双侧同域，注册与比较都用它。
3. **缩减 SDK FSEvents 签名两处偏差**（见 S1 定档）。
4. **Stop/Release 不等在途回调退出（评审 C1，探针实测）**：deinit 可先于回调体完成
   打印 → `info: passUnretained` 无 retain 回调 = use-after-free。定档 = CF 标准配对：
   `passUnretained` + retain/release 回调——CF **创建时**经 retain 回调自取 +1（探针
   count 2→3），流彻底析构时 release 回调归还；对象寿命由流托住。**不可**叠加
   `passRetained`（=+2 泄漏，探针证伪）。本 SDK 把 retain/release 导入为**单参** C 闭包
   （` (UnsafeRawPointer?) -> UnsafeRawPointer?`，非传统 3 参 CFAllocatorRetainCallBack）。
   release 回调**异步于 stop() 返回**（测试轮询 ≤3s 才落定）。创建失败路不手动配平
   引用（CF 失败路径是否已调 retain 不可证，宁漏不崩）。
5. **注销滞后窗口（评审 C2）**：注销挂在 load→onReload 尾，`setSource` 同步改
   path/source 后远端走 loadAsync → 注销滞后一个网络 RTT。窗口内 entries 在册而 pane
   已远端化 → 事件路去抖落定/refreshAllWatched 会对远端源**同步** load →
   SFTP performSync（NSLock+信号量）冻结主线程。修 = **使用时刻复查**
   `entry.pane.path.url.isFileURL`（违约就地注销）+ Favorites.jump 换源后同步补一次
   noteReloaded（此刻 path 已是新值）。
6. **resolvingSymlinksInPath 解析末段（评审 C3）**：它对路径上**每一个**链出手，含
   末段——目录里 `link -> /etc/hosts` 的事件路径被整条改写出 watched 域 → 该文件
   create/rename 恒不触发刷新（探针实证 parent==watched false）。修 = 只解**父目录**
   链，末段名原样接回。

## 已知取舍（含评审 minor 裁定）

- **自激环**：app 自身操作后 FSEvents 迟到再触发恰好一次多余 `load(preserveFocus:true)`
  ——幂等、焦点标记保留、本地 2 万项实测 37ms。接受不抑制；抑制挂点=记录
  lastSelfLoadTime 做 500ms 短路（注释在位）。
- **焦点项被外部删**：`SelectionModel.swift:32` 焦点项消失 → 失焦 → 清空整组 marked。
  自动刷新让「无操作标记莫名消失」变可见。v1 接受；后续独立改 formIntersection。
- **焦点行真窗断言**：PaneTableView 焦点未投影为 AX selected → UI 层该用例 XCTSkip，
  焦点保留合同由 SPM 强锁（focusID 断言）。
- **监听目录被删**：刷一次吃 load 错误路（空列表 + lastError），不注销流（目录重建后
  事件路继续工作；didBecomeActive 亦兜底）。
- **既有 Tier-1 wiring 测试**构造 MainViewController 现挂真 FSEvents 流在临时夹具目录
  （低风险：刷新保焦点幂等）；若显 flaky → 给测试注 no-op 工厂。
- **minor 裁定（评审 7 条全记此表）**：① refreshAllWatched 对多标签目录是 N 连同步
  load（成本随标签数线性，个位数标签可接受）；② FSEventStreamCreate 返回 nil 静默
  return（罕见资源耗尽，无用户可见信号）；③ 路径过滤的大小写/Unicode 规范化域
  （APFS 大小写保留卷上 `A.txt` 事件与 `a.txt` 注册不等值——跟随文件系统语义，不额外
  折叠）；④ loadAsync 回包路焦点快照时序与同步路微差（罕见，幂等重载兜住）；
  ⑤ 空转流锚注释（已订正）；⑥ UI ⌃R 用例窗口计数放宽 ≤1（已改
  XCTAssertLessThanOrEqual）；⑦ KeyDispatcher ⌃R 负锁（已加
  testControlRNotDoubleRegistered）。

## 测试面

- **SPM DirectoryWatcherCoordinatorTests（19 条）**：注册/判据/换路径恰一对 stop+start/
  同路径 no-op/注销吞迟到批/换源注销/去抖合并 5→1（变异证伪：删 pending 守卫→5 红）/
  深层忽略/兜底 flag 无条件刷/目录删刷空/refreshAllWatched 只刷已注册+取消挂起项/
  VC onReload 链接线锁/closeTab 注销线锁 + 评审轮 5 条：C1 retain/release 回调 1:1 配对
  （变异 nil→创建计数 0 红）/C2 事件路+兜底路使用点复查双锁（变异删复查→首断言即红
  ——继续失败关闭下 stopCount 0 先于 mainThreadLoads 被测到）/C3 外部软链事件仍刷
  （变异整条 comparable→0 红）/裁决①全标签含后台挂流端到端/URL== 活语义回归锁
  （变异改回 `==`→重挂+误停双红）。
- **SPM 手动刷新（#27 已并入）**：CommandRouterTests 3 条（保焦点/clamp/远端异步）、
  MainMenuTests ⌃R 键位、InternalCommandExecutorTests refresh 命令。
- **XCUITest AutoRefreshUITests（4 条）**：真跨进程 create→行现 / delete→行消 /
  ⌃R 弱锁+S2 / 焦点行（skip 语义）。
