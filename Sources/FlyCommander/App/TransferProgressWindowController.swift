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
    var probe: (ended: Bool, bar: NSProgressIndicator, title: NSTextField,
                fileName: NSTextField, detailLabel: NSTextField, routeLabel: NSTextField,
                cancel: NSButton) {
        (ended, progressBar, titleLabel, fileNameLabel, detailLabel, routeLabel, cancelButton)
    }
    #endif

    /// 语言变更后经主 VC 调用：仅当已创建才重刷静态文案，绝不建窗。
    static func refreshLocalizedTextIfCreated() { _shared?.refreshLocalizedText() }

    private let titleLabel = NSTextField(labelWithString: "")
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let routeLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton()

    /// 本次传输的取消旗（present 时注入；按钮/Esc 置位）。
    private var cancel: CancelFlag?
    /// 速度样本（时刻, 累计字节）——TransferSpeed.estimate 的输入。
    private var samples: [(t: TimeInterval, bytes: Int64)] = []
    /// 上一帧文件名（字节帧 name="" 时沿用）。
    private(set) var lastFileName = ""
    private var dismissWorkItem: DispatchWorkItem?
    private var ended = false          // 本次传输已收到终态（done/failed）
    private var isCopy = true          // 本次传输动词（presentTransfer 注入，apply 标题用）

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 168),
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
        routeLabel.font = .systemFont(ofSize: 11)
        routeLabel.textColor = .secondaryLabelColor
        routeLabel.lineBreakMode = .byTruncatingTail
        routeLabel.translatesAutoresizingMaskIntoConstraints = false

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
        content.addSubview(routeLabel)
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

            routeLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 8),
            routeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            routeLabel.widthAnchor.constraint(lessThanOrEqualTo: detailLabel.widthAnchor),

            cancelButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
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
        dismissWorkItem?.cancel()
        titleLabel.stringValue = L10n.t(isCopy ? .opCopying : .opMoving, "\(fileTotal)")
        fileNameLabel.stringValue = ""
        detailLabel.stringValue = ""
        routeLabel.stringValue = ""
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
            routeLabel.stringValue = Self.routeText(route)
        }
        if let done = info.bytesDone, let total = info.bytesTotal, total > 0 {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = Double(done) / Double(total) * 100
            samples.append((CFAbsoluteTimeGetCurrent(), done))
            if samples.count > 64 { samples.removeFirst(samples.count - 64) }
            // 字节计数纯数字+斜杠（无文案）不需 L10n 键。
            var detail = "\(Self.byteString(done)) / \(Self.byteString(total))"
            if let speed = TransferSpeed.estimate(samples: samples) {
                detail += "  " + L10n.t(.transSpeed, Self.byteString(Int64(speed)))
                let remaining = Double(total - done) / speed
                if remaining < 3600 * 24 {   // >24h 的估算没有意义，宁缺毋假
                    detail += "  " + L10n.t(.transRemaining, Self.durationString(remaining))
                }
            }
            detailLabel.stringValue = detail
        } else {
            // 文件级帧（或大小未知）：字节黑盒 → 扫动态。
            if !progressBar.isIndeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
        }
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
            progressBar.doubleValue = 100
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
        case .relayed(let reason):
            switch reason {
            case .execRejected: return L10n.t(.transRelayedExecRejected)
            case .cpMissing: return L10n.t(.transRelayedCpMissing)
            case .unsupportedFlags: return L10n.t(.transRelayedUnsupportedFlags)
            case .channelGone: return L10n.t(.transRelayedChannelGone)
            }
        }
    }
}
