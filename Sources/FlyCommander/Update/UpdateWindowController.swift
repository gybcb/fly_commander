import AppKit
import TCCore

/// 软件更新窗（仿 TransferProgressWindowController：非模态单窗复用 + orderOut 关窗）。
/// 三态：available（发现新版）→ installing（阶段进度）→ done（Gatekeeper 指引 + 复制命令 + 重启）。
/// 失败不走本窗（关窗 + NSAlert，updateFailed 文案）。
final class UpdateWindowController: NSWindowController {
    private static var _shared: UpdateWindowController?
    static var shared: UpdateWindowController {
        if let s = _shared { return s }
        let s = UpdateWindowController(); _shared = s; return s
    }
    enum State { case available, installing, done }
    private(set) var state: State = .available

    /// 由 flow 注入（按钮回调转发）。
    var onUpgrade: (() -> Void)?
    var onSkip: (() -> Void)?
    var onRelaunch: (() -> Void)?

    /// 升级完成后的版本号（done 态文案用）。
    private var newVersion = ""

    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let notesLabel = NSTextField(wrappingLabelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let commandField = NSTextField(string: "")
    private let skipButton = NSButton()
    private let laterButton = NSButton()
    private let upgradeButton = NSButton()
    private let copyButton = NSButton()
    private let restartButton = NSButton()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L10n.t(.updateWindowTitle)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        messageLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        notesLabel.font = .systemFont(ofSize: 12)
        notesLabel.textColor = .secondaryLabelColor
        phaseLabel.font = .systemFont(ofSize: 12)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        // 红线配套：指引命令是「给用户看/复制」的文本，selectable 供手动拷贝，
        // 本窗任何路径都不会执行它。
        commandField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        commandField.isSelectable = true
        commandField.isEditable = false
        commandField.isBordered = false
        commandField.drawsBackground = false
        commandField.lineBreakMode = .byTruncatingMiddle

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.controlSize = .large

        configureButton(skipButton, key: .skipVersionBtn, action: #selector(skipPressed))
        configureButton(laterButton, key: .laterBtn, action: #selector(laterPressed))
        configureButton(upgradeButton, key: .upgradeBtn, action: #selector(upgradePressed))
        configureButton(copyButton, key: .copyCmdBtn, action: #selector(copyPressed))
        configureButton(restartButton, key: .restartNowBtn, action: #selector(restartPressed))
        upgradeButton.keyEquivalent = "\r"
        laterButton.keyEquivalent = "\u{1b}"
        // AX 契约：UITest 按 identifier 定位（表格 identifier 不可达坑不适用于按钮）。
        upgradeButton.setAccessibilityIdentifier("update.upgrade")
        skipButton.setAccessibilityIdentifier("update.skip")
        laterButton.setAccessibilityIdentifier("update.later")
        copyButton.setAccessibilityIdentifier("update.copy")
        restartButton.setAccessibilityIdentifier("update.restart")

        for v in [messageLabel, notesLabel, phaseLabel, progressBar, hintLabel, commandField] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        let buttonRow = NSStackView(views: [skipButton, laterButton, upgradeButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 10
        let doneRow = NSStackView(views: [copyButton, restartButton])
        doneRow.orientation = .horizontal
        doneRow.distribution = .fillEqually
        doneRow.spacing = 10

        let stack = NSStackView(views: [messageLabel, notesLabel, phaseLabel, progressBar,
                                        hintLabel, commandField, buttonRow, doneRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        // SFTP 按钮裁切坑先例：内容栈 bottom 钉死 → 窗高随内容 autogrow，按钮永不被裁。
        for b in [buttonRow, doneRow] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notesLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            commandField.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyAvailableState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureButton(_ b: NSButton, key: L10nKey, action: Selector) {
        b.title = L10n.t(key)
        b.bezelStyle = .rounded
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - 状态机（恒主线程调用；installer 回调经 flow 的 onMain 投递）

    private func applyAvailableState() {
        state = .available
        notesLabel.isHidden = false
        phaseLabel.isHidden = true
        progressBar.isHidden = true
        progressBar.stopAnimation(nil)
        hintLabel.isHidden = true
        commandField.isHidden = true
        skipButton.isHidden = false
        laterButton.isHidden = false
        upgradeButton.isHidden = false
        copyButton.isHidden = true
        restartButton.isHidden = true
    }

    private func applyInstallingState() {
        state = .installing
        phaseLabel.isHidden = false
        progressBar.isHidden = false
        progressBar.startAnimation(nil)
        skipButton.isHidden = true
        laterButton.isHidden = true
        upgradeButton.isHidden = true
        messageLabel.stringValue = ""
        notesLabel.isHidden = true
    }

    private func applyDoneState(version: String) {
        state = .done
        newVersion = version
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true
        phaseLabel.isHidden = true
        messageLabel.stringValue = L10n.t(.updateDone, version)
        hintLabel.stringValue = L10n.t(.gatekeeperHint)
        hintLabel.isHidden = false
        commandField.stringValue = gatekeeperCommandText
        commandField.isHidden = false
        copyButton.isHidden = false
        restartButton.isHidden = false
    }

    /// 安装阶段推进（onPhase 帧）。
    func applyPhase(_ phase: UpdateInstaller.Phase) {
        guard state == .installing else { return }
        phaseLabel.stringValue = L10n.t(Self.phaseKey(phase))
    }

    /// Gatekeeper 指引命令（done 态显示文本，红线：仅展示/复制，本窗永不执行）。
    var gatekeeperCommandText: String = ""

    static func phaseKey(_ phase: UpdateInstaller.Phase) -> L10nKey {
        switch phase {
        case .download: return .updatePhaseDownload
        case .verify: return .updatePhaseVerify
        case .replace: return .updatePhaseReplace
        }
    }

    // MARK: - 上屏

    /// 发现新版本：填文案后居中弹出（幂等，重复 present 只刷新内容）。
    func presentAvailable(manifest: UpdateManifest, localVersion: String) {
        applyAvailableState()
        messageLabel.stringValue = L10n.t(.updateAvailable, manifest.version, localVersion)
        notesLabel.stringValue = manifest.notes
        presentWindow()
    }

    /// 升级开始：切 installing 态（须已由 presentAvailable 上屏）。
    func beginInstalling() {
        applyInstallingState()
        window?.layoutIfNeeded()
    }

    func finishSuccess(version: String) {
        applyDoneState(version: version)
        window?.layoutIfNeeded()
    }

    /// 失败收口：关窗（错误提示由 flow 的 NSAlert 负责，不叠窗）。
    func finishFailure() {
        window?.orderOut(nil)
    }

    private func presentWindow() {
        window?.layoutIfNeeded()   // center 前排版（SFTP 首开落位坑先例）
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 按钮

    @objc private func upgradePressed() { onUpgrade?() }
    @objc private func laterPressed() { window?.orderOut(nil) }
    @objc private func skipPressed() { onSkip?(); window?.orderOut(nil) }
    @objc private func restartPressed() { onRelaunch?() }
    @objc private func copyPressed() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commandField.stringValue, forType: .string)
    }

    func refreshLocalizedText() {
        window?.title = L10n.t(.updateWindowTitle)
        skipButton.title = L10n.t(.skipVersionBtn)
        laterButton.title = L10n.t(.laterBtn)
        upgradeButton.title = L10n.t(.upgradeBtn)
        copyButton.title = L10n.t(.copyCmdBtn)
        restartButton.title = L10n.t(.restartNowBtn)
        if state == .done { messageLabel.stringValue = L10n.t(.updateDone, newVersion) }
    }

    static func refreshLocalizedTextIfCreated() { _shared?.refreshLocalizedText() }
}
