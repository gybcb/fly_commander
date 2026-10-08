import AppKit
import TCCore

/// 传输进度面板（T3）：非模态单窗复用（PreviewWindowController 先例）。
///
/// - 字节进度已知 → determinate 进度条 + 百分比 + 速度/剩余；
///   未知（同源 cp / 大小未知）→ indeterminate 扫动条。
/// - 副标题显示 CopyRoute（服务器端复制 / 本机中转+原因）——回退可见化的落点。
/// - 取消按钮置 CancelFlag（生效边界=引擎三层取消语义）；Esc 等同取消。
/// - 成功驻留 0.8s 自动关；失败驻留等用户（先关面板再由 state 通道弹错误，避免叠窗）。
final class TransferProgressWindowController: NSWindowController {
    private static var _shared: TransferProgressWindowController?
    static var shared: TransferProgressWindowController {
        if let s = _shared { return s }
        let s = TransferProgressWindowController(); _shared = s; return s
    }
    #if DEBUG
    /// 测试用：窗口是否已创建（语言重刷守卫断言）。
    static var hasCreatedWindowForTest: Bool { _shared != nil }
    static func resetSharedForTest() { _shared?.closePanel(); _shared = nil }
    /// 测试用：建窗不上屏，供控件构造断言。
    static func createWithoutPresentingForTest() -> TransferProgressWindowController { shared }
    /// 测试用：模拟点取消按钮（同 #selector 目标，SPM 无 sendAction 便利）。
    func clickCancelButtonForTest() { cancelPressed() }
    /// 测试用：内部状态只读（构造断言 + 收口语义断言）。
    /// routeDotGreen：nil = 点隐藏（无 route），true = 绿（字节不出服务器/服务器对），false = 黄（本机中转）。
    /// speedLabel = 去闪改造后的右段（速度·剩余），见 setDetail。
    var probe: (ended: Bool, bar: NSProgressIndicator, title: NSTextField,
                fileName: NSTextField, detailLabel: NSTextField, speedLabel: NSTextField,
                routeLabel: NSTextField,
                cancel: NSButton, routeDotGreen: Bool?) {
        (ended, progressBar, titleLabel, fileNameLabel, detailLabel, speedLabel, routeLabel, cancelButton, routeDotGreen)
    }
    /// 测试用：不经进度帧直接驱动色点/文案分支。
    func applyProbeRoute(_ route: CopyRoute?) { apply(route: route) }
    /// 测试用：detail 文本时钟注入（样本时间戳与 250ms 重写闸共用）。冻结 = 闸恒关。
    var testDetailClock: (() -> TimeInterval)?
    /// 测试用：detail 文本实际发生重写的次数（同内容去重 + 250ms 闸后计数）。
    private(set) var detailRewriteCount = 0
    #endif

    /// 语言变更后经主 VC 调用：仅当已创建才重刷静态文案，绝不建窗。
    static func refreshLocalizedTextIfCreated() { _shared?.refreshLocalizedText() }

    private let titleLabel = NSTextField(labelWithString: "")
    private let fileNameLabel = NSTextField(labelWithString: "")
    /// detail 行 = 左右两 label（去闪）：左 = 已传/总量（钉 leading），
    /// 右 = 速度 · 剩余（右对齐钉 trailing）。单串拼接时三段各自变宽 →
    /// 整行字符左右推挤（用户报「一跳一跳，字看不清楚」）；拆双锚后
    /// 宽度波动被两侧吸收，数字不再互推。
    private let detailLabel = NSTextField(labelWithString: "")
    private let speedLabel = NSTextField(labelWithString: "")
    private let routeLabel = NSTextField(labelWithString: "")
    /// 路径色点：绿 = 字节不过本机（serverSide / directCrossHost），黄 = 本机中转。
    private let routeDot = RouteDotView()
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton()

    #if DEBUG
    /// 色点当前语义色（内部状态，仅供 probe 读出；见 probe.routeDotGreen）。
    private(set) var routeDotGreen: Bool?
    #endif

    /// 本次传输的取消旗（present 时注入；按钮/Esc 置位）。
    private var cancel: CancelFlag?
    /// 速度样本（时刻, 累计字节）——TransferSpeed.estimate 的输入。
    private var samples: [(t: TimeInterval, bytes: Int64)] = []
    /// 平滑后速度（EMA）。TransferSpeed.estimate 的 0.5s 尾窗原始值逐帧抖动
    /// （单个慢块进出窗口即跳），显示层用 α=0.25 一阶滤波吃掉抖动；
    /// 原始估算与样本合同一字不动。resetForTransfer 清 nil。
    private var smoothedSpeed: Double?
    /// 上次 detail 文本重写时刻（与文本内容）——250ms 重写闸 + 同内容去重。
    /// 节流闸 0.05s = 20Hz 整行重写是「闪」的直接来源；文本降到 ~4Hz 可读刷新率，
    /// 进度条不受此闸（条走动是进度感）。resetForTransfer 清零。
    private var lastDetailWriteTime: TimeInterval = -.infinity
    private var lastDetailTexts: (left: String, right: String)?
    private static let detailRewriteInterval: TimeInterval = 0.25
    /// 条上次实际写入的百分比（像素量化闸）：变化 <0.25pt（≈1px，396pt 条）
    /// 不写 —— 超大总量批次每帧增量是亚像素，逐帧写 = AppKit 插值重绘 =
    /// 「滚来滚去」（真机日志实证 2026-10-08：112.5GB 批次条恒 determinate
    /// 但全程肉眼不动）。收口 100 与首写不受闸。resetForTransfer 清 nil。
    private var barLastPct: Double?
    private static let barPixelGranularity: Double = 0.25
    /// 取时（样本时间戳与重写闸共用）：测试注入假时钟，默认真实时钟。
    private func nowTime() -> TimeInterval {
        #if DEBUG
        if let c = testDetailClock { return c() }
        #endif
        return CFAbsoluteTimeGetCurrent()
    }
    /// 上次成功写条用的是**字节坐标**（聚合 or 单文件字节）还是文件数/扫动。
    /// 纯文件完成帧（无 overall、无字节）据此决定碰不碰条：字节真值已在场上 →
    /// 不回退、不改值（锁 E）；只有文件数条或还在扫动 → 按文件完成度推进（锁 F）。
    /// resetForTransfer 清 false。
    private var lastBarIsByte = false
    /// 聚合值闩（本次传输见过聚合帧 → 进度条/速度**永久**用聚合坐标）。
    /// pump 路字节帧与聚合帧逐块交替到闸（两闸独立），无闩则条在「单文件% ↔
    /// 全进度%」锯齿；且两套 done 混喂 samples → 文件切换瞬间 db<0 → 速度恒 nil
    /// （TransferSpeed.estimate 的 db>=0 守卫）。resetForTransfer 清零（无聚合路
    /// 恒 false = 现状行为一字不动）。
    private var overallLatched = false
    /// 上一帧文件名（字节帧 name="" 时沿用）。
    private(set) var lastFileName = ""
    private var dismissWorkItem: DispatchWorkItem?
    private var ended = false          // 本次传输已收到终态（done/failed）
    private var isCopy = true          // 本次传输动词（presentTransfer 注入，apply 标题用）

    private init() {
        let window = NSWindow(
            // 168→190：路由行独立成行（旧形与 detail 同基线）后固定高容不下，
            // 路由文案被切进取消按钮区（截图实证）。
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L10n.t(.transferring)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        // 缩减 SDK 坑：程序化约束子视图必须 translatesAutoresizingMaskIntoConstraints=false。
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.controlSize = .large
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .systemFont(ofSize: 12)
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.alignment = .right
        speedLabel.lineBreakMode = .byTruncatingTail
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        routeLabel.font = .systemFont(ofSize: 11)
        routeLabel.textColor = .secondaryLabelColor
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.translatesAutoresizingMaskIntoConstraints = false

        routeDot.isHidden = true
        routeDot.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.title = L10n.t(.transCancel)
        cancelButton.bezelStyle = .rounded
        // Esc = 取消：直挂 keyEquivalent（本仓库 NSAlert 取消键同款先例）。
        // cancelOperation 响应者链兜底保留——按钮禁用后 keyEquivalent 不再触发，链兜底幂等。
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(titleLabel)
        content.addSubview(fileNameLabel)
        content.addSubview(progressBar)
        content.addSubview(detailLabel)
        content.addSubview(speedLabel)
        content.addSubview(routeLabel)
        content.addSubview(routeDot)
        content.addSubview(cancelButton)
        window.contentView = content

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            fileNameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            fileNameLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            fileNameLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            progressBar.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 10),
            progressBar.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 14),

            detailLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            // 左右分栏：detail ≤80%、speed ≥20% 共存（左段短、右段可截尾不互推）。
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: speedLabel.leadingAnchor,
                                                  constant: -8),

            // 右段 = 速度·剩余：顶对齐 detail（同一行），右对齐钉 trailing。
            speedLabel.topAnchor.constraint(equalTo: detailLabel.topAnchor),
            speedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailLabel.trailingAnchor),
            speedLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            // 路由行 = detail 之下**独立一行**（旧形与 detail 同基线一头尾对钉，
            // 路由文案变长就撞进「字节+速度」串里 = 用户报的重叠）。
            // 色点在文本左侧（行左对齐后 trailing 不再由内容导出，点改钉 leading）。
            routeLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 4),
            routeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            routeLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),

            routeDot.widthAnchor.constraint(equalToConstant: 9),
            routeDot.heightAnchor.constraint(equalToConstant: 9),
            routeDot.centerYAnchor.constraint(equalTo: routeLabel.centerYAnchor),
            routeDot.leadingAnchor.constraint(equalTo: routeLabel.leadingAnchor, constant: -12),

            // 按钮在两条信息行之下（隐藏的路由行仍占位=固定高窗口本有空间）。
            // 双 required ≥：取 max(detail.bottom+12, route.bottom+4)，无歧义不冲突。
            cancelButton.topAnchor.constraint(greaterThanOrEqualTo: detailLabel.bottomAnchor,
                                              constant: 12),
            cancelButton.topAnchor.constraint(greaterThanOrEqualTo: routeLabel.bottomAnchor,
                                              constant: 4),

            cancelButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 生命周期（全部主线程；TransferEngine 回调已经 onMain 投递）

    /// 传输开始：复位面板、注入取消旗、上屏。isCopy 决定标题动词（复制/移动）。
    func presentTransfer(isCopy: Bool, fileTotal: Int, cancel: CancelFlag) {
        resetForTransfer(isCopy: isCopy, fileTotal: fileTotal, cancel: cancel)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 复位（不含上屏）。presentTransfer 拆出来给测试 headless 驱动 apply/finish，
    /// 避免 swift test 里真把窗口 orderFront 闪屏（ResidentWindowRepaintTests 同法）。
    private func resetForTransfer(isCopy: Bool, fileTotal: Int, cancel: CancelFlag) {
        self.cancel = cancel
        self.isCopy = isCopy
        ended = false
        lastFileName = ""
        samples = []
        overallLatched = false
        lastBarIsByte = false
        smoothedSpeed = nil
        lastDetailWriteTime = -.infinity
        lastDetailTexts = nil
        barLastPct = nil
        #if DEBUG
        detailRewriteCount = 0
        #endif
        dismissWorkItem?.cancel()
        titleLabel.stringValue = L10n.t(isCopy ? .opCopying : .opMoving, "\(fileTotal)")
        fileNameLabel.stringValue = ""
        detailLabel.stringValue = ""
        speedLabel.stringValue = ""
        apply(route: nil)
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        cancelButton.isEnabled = true
        cancelButton.title = L10n.t(.transCancel)
    }
    #if DEBUG
    /// 测试用：只复位不上屏，供 headless 驱动 apply/finish 断言。
    func resetForTransferForTest(isCopy: Bool, fileTotal: Int, cancel: CancelFlag) {
        resetForTransfer(isCopy: isCopy, fileTotal: fileTotal, cancel: cancel)
    }
    #endif

    /// 进度帧（TransferEngine.onProgress，主线程）。
    func apply(_ info: TransferEngine.TransferProgressInfo) {
        guard !ended else { return }
        // 标题 = 「复制/移动 N 个文件 · 文件级 done/total」（op* 携总数）。
        titleLabel.stringValue = L10n.t(isCopy ? .opCopying : .opMoving, "\(info.fileTotal)")
            + " · " + "\(info.fileDone)/\(info.fileTotal)"
        if !info.name.isEmpty {
            lastFileName = info.name
            fileNameLabel.stringValue = info.name
        }
        if let route = info.route {
            apply(route: route)
        }
        // 聚合优先（spec §3.4）：见过聚合帧（本帧携带 or 闩已置）→ 条/百分比/
        // 字节数/速度样本/剩余**全部**用聚合坐标；无 overall 的单文件帧只更新
        // 标题/文件名/色点（上方已做），**不得**碰条与 samples——两套 done 混喂
        // 会让文件切换的 done 回跳污染速度（db<0 → 速度恒 nil）+ 条锯齿。
        // 速度样本喂聚合 done → 跨文件不重置、无 100%→0%（用户报障正面解）。
        if let oDone = info.overallBytesDone, let oTotal = info.overallBytesTotal, oTotal > 0 {
            overallLatched = true
            lastBarIsByte = true
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            setBar(Double(oDone) / Double(oTotal) * 100)
            let t = nowTime()
            samples.append((t, oDone))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            // 百分比数字必须上屏：超大总量（真机 112.5GB）下条增量恒亚像素
            // = 肉眼不动，数字是唯一「进度在走」的可读信号（真机日志实证）。
            let pct = String(format: " %.1f%%", min(100, Double(oDone) / Double(oTotal) * 100))
            renderDetail(bytesText: "\(Self.byteString(oDone)) / \(Self.byteString(oTotal))" + pct,
                         remainingAgainst: oTotal, done: oDone, at: t)
            return
        }
        if overallLatched { return }   // 闩后单文件帧（无 overall）不碰条/速度
        if let done = info.bytesDone, let total = info.bytesTotal, total > 0 {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            // done>total 只可能是解析器对 openrsync 反推总量的整型瞬时误差（帧是逐条目
            // 同源合同，终审 B2 后无稳态越界）→ 钳 100 防回绕显示。
            lastBarIsByte = true
            setBar(Double(done) / Double(total) * 100)
            let t = nowTime()
            samples.append((t, done))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            // 字节计数纯数字+斜杠（无文案）不需 L10n 键。
            renderDetail(bytesText: "\(Self.byteString(done)) / \(Self.byteString(total))",
                         remainingAgainst: total, done: done, at: t)
        } else if let done = info.bytesDone {
            // 有字节 done、无有效 total（直传目录条目 total=0→nil）：字节条算不出，
            // 但**能算的地方用真条**——多文件按文件完成度走 determinate；
            // 单文件 0/1 无比例意义 → 维持扫动（不卡 0% 假 determinate）。
            // 字节数与速度**照给**（spec §3「两路都有速度」，无分母式 = 字节 · 速度）。
            setFileCountBar(info: info)
            let t = nowTime()
            samples.append((t, done))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            renderDetail(bytesText: Self.byteString(done),
                         remainingAgainst: nil, done: done, at: t)
        } else {
            // 纯文件完成/路由帧（bytesDone=nil、无 overall）：本帧无新字节信息。
            // 假条根因修法——条**已是**字节真值（前一 pump/聚合帧走过 determinate）
            // → 不回扫、不改值（旧 else 无条件 startAnimation = 每传完一个文件
            // 真条闪回扫动 = 用户报「假进度条」）。条**还在扫动**（本批次尚无任何字节
            // 坐标）→ 多文件按文件完成度走真条；单文件维持扫动。
            if !lastBarIsByte { setFileCountBar(info: info) }   // 字节真值在场 → 完成帧不碰条
            // detail 不重渲染（无新字节，条不闪）。
        }
    }

    /// 条写入唯一入口（像素量化闸）：Δ<0.25pt（≈1px）跳过 = 超大总量下
    /// 亚像素增量逐帧写会让条「原地滚」（真机实证）；收口 100 与首写必过。
    private func setBar(_ pct: Double) {
        let v = min(100, max(0, pct))
        if let last = barLastPct, abs(v - last) < Self.barPixelGranularity, v < 100 { return }
        barLastPct = v
        progressBar.doubleValue = v
    }

    /// 无字节坐标时的条降级：多文件 → 按 fileDone/fileTotal 走 determinate 真条
    /// （「能明确计算的地方用真条」）；单文件（fileTotal≤1）无比例意义 → 扫动。
    /// 走过本函数 = 条离开字节坐标（锁 E 的「不回退」判据据此翻转）。
    private func setFileCountBar(info: TransferEngine.TransferProgressInfo) {
        if info.fileTotal > 1 {
            lastBarIsByte = false
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            setBar(Double(info.fileDone) / Double(info.fileTotal) * 100)
        } else if !progressBar.isIndeterminate {
            lastBarIsByte = false
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }
    }

    /// detail 行刷新（去闪三合一定）：EMA 每帧推进（estimate 原始值不动，
    /// 0.5s 尾窗抖动在显示层阻尼）；剩余额按平滑速度算（0.1s 位永远在跳，
    /// durationString 本就四舍五入整秒）；文本经 250ms 重写闸 + 同内容去重
    /// （NSTextField 空赋值也触发重绘，必须比对后跳过）。进度条由调用方
    /// 先写、**不**走本闸——条走动是进度感，不是闪。
    private func renderDetail(bytesText: String, remainingAgainst total: Int64?,
                              done: Int64, at t: TimeInterval) {
        smoothedSpeed = Self.smooth(prev: smoothedSpeed,
                                    raw: TransferSpeed.estimate(samples: samples))
        var right = ""
        if let sp = smoothedSpeed, sp > 0 {
            right = L10n.t(.transSpeed, Self.byteString(Int64(sp)))
            if let total {
                // 剩余钳 ≥0：done>total 的越界帧会给负剩余（同 reason 同钳位）。
                let remaining = max(0, Double(total - done) / sp)
                if remaining < 3600 * 24 {   // >24h 的估算没有意义，宁缺毋假
                    right += "  " + L10n.t(.transRemaining, Self.durationString(remaining))
                }
            }
        }
        guard t - lastDetailWriteTime >= Self.detailRewriteInterval else { return }
        guard lastDetailTexts?.left != bytesText || lastDetailTexts?.right != right else { return }
        lastDetailWriteTime = t
        lastDetailTexts = (bytesText, right)
        detailLabel.stringValue = bytesText
        speedLabel.stringValue = right
        #if DEBUG
        detailRewriteCount += 1
        #endif
    }

    /// 速度 EMA（显示层）：α=0.25 ≈ 4 帧收敛大半；raw=nil（窗口不足/断流）
    /// → 保持上次值——清零是新的闪源，残留旧值随后被新样本拉回。
    static func smooth(prev: Double?, raw: Double?, alpha: Double = 0.25) -> Double? {
        guard let raw else { return prev }
        guard let prev else { return raw }
        return prev + alpha * (raw - prev)
    }

    /// 路径副标题 + 色点。`route == nil`（引擎还没报路径）→ 整行隐藏。
    /// 色点语义：**绿 = 字节从未过本机**（服务器端 cp / 跨服务器直传），黄 = 本机中转 pump。
    private func apply(route: CopyRoute?) {
        if let route { routeLabel.stringValue = Self.routeText(route) }
        let green = route.map { $0 == .serverSide || $0 == .directCrossHost }
        #if DEBUG
        routeDotGreen = green
        #endif
        if let green {
            routeDot.dotGreen = green
        }
        routeLabel.isHidden = route == nil
        routeDot.isHidden = route == nil
    }

    /// 终态。OperationState 只用于 done/failed；**取消不走这里**——冲突对话框取消同样
    /// 报 .idle（歧义源），取消收口 = transferEngine.onFinished → finishCancelled()。
    func finish(state: OperationState) {
        guard !ended else { return }
        switch state {
        case .done:
            ended = true
            dismissWorkItem?.cancel()
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            setBar(100)
            titleLabel.stringValue = L10n.t(.transDone)
            cancelButton.isEnabled = false
            // 成功 0.8s 自动关（用户来得及瞥见 100%）。
            let item = DispatchWorkItem { [weak self] in self?.closePanel() }
            dismissWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
        case .failed:
            // 失败驻留：等用户看名字/字节位置；错误文案状态栏已给，面板不抢焦点。
            ended = true
            dismissWorkItem?.cancel()
            progressBar.stopAnimation(nil)
            cancelButton.isEnabled = false
        default:
            break
        }
    }

    /// 取消收口（onFinished 无条件到达）：立即关。
    func finishCancelled() {
        guard !ended else { return }
        ended = true
        closePanel()
    }

    /// 面板当前是否可见（主 VC 的 state 旁路用于判断"该不该把状态喂给我"）。
    var isShowingTransfer: Bool { window?.isVisible == true && !ended }

    @objc private func cancelPressed() {
        cancel?.cancel()
        // 取消生效在后台块（文件/块边界）；面板原地等 idle 终态，不提前关。
        cancelButton.isEnabled = false
    }

    override func cancelOperation(_ sender: Any?) { cancelPressed() }   // Esc

    // 注：不拦截红 X——NSWindowController 不是自己窗口的 delegate，且"关窗即取消"
    // 是比静默后台跑更重的语义决定；取消入口=按钮/Esc（置旗后传输在边界干净收尾）。

    private func closePanel() {
        dismissWorkItem?.cancel()
        window?.orderOut(nil)
    }

    private func refreshLocalizedText() {
        window?.title = L10n.t(.transferring)
        cancelButton.title = L10n.t(.transCancel)
    }

    // MARK: - 纯格式化（internal：SPM 直测）

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// 秒 → "1:23"（分:秒）或 "2h+" 封顶；负/NaN → ""。封顶在四舍五入**之后**判，
    /// 否则 7199.6 会打出 "120:00" 越顶。
    static func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let s = Int(seconds.rounded())
        if s >= 7200 { return "2h+" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func routeText(_ route: CopyRoute) -> String {
        switch route {
        case .serverSide: return L10n.t(.transServerSide)
        case .directCrossHost: return L10n.t(.transDirectCrossHost)
        case .relayed(let reason):
            switch reason {
            case .execRejected: return L10n.t(.transRelayedExecRejected)
            case .cpMissing: return L10n.t(.transRelayedCpMissing)
            case .unsupportedFlags: return L10n.t(.transRelayedUnsupportedFlags)
            case .channelGone: return L10n.t(.transRelayedChannelGone)
            case .needsAuth: return L10n.t(.transRelayedNeedsAuth)
            case .rsyncMissing: return L10n.t(.transRelayedRsyncMissing)
            }
        }
    }
}

/// 路由色点：自绘实心圆 + 同色 25% 透明光晕环（LED 质感，替代旧平涂 layer 圆角方块）。
/// 动态色必须在 draw 内、以视图自身 effectiveAppearance 为上下文解析——
/// init 定格 cgColor 会在明暗切换/复用路径读旧 currentDrawing（2026-09-14 实测坑），
/// 故颜色在 draw 里现取，绝不在赋值时算好存 layer。
final class RouteDotView: NSView {
    /// nil = 未上色（隐藏中）；true = 绿；false = 黄。setNeedsDisplay 驱动重绘。
    var dotGreen: Bool? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let green = dotGreen, let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.cgContext.setShouldAntialias(true)
        let color = green ? NSColor.systemGreen : NSColor.systemYellow
        // 光晕环：外圈 1pt 宽、25% 透明同色（bounds 内缩 0.5 防裁切）。
        color.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        // 实心核。
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        ctx.restoreGraphicsState()
    }
}
