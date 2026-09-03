import AppKit
import TCCore

final class SMBConnectionViewController: NSViewController {
    var onConnected: ((SMBSource, TCPath) -> Void)?

    // MARK: - 表单控件
    private let serverField = NSTextField(frame: .zero)
    private let shareField = NSTextField(frame: .zero)
    private let domainField = NSTextField(frame: .zero)
    private let userField = NSTextField(frame: .zero)
    private let passwordField = NSSecureTextField(frame: .zero)
    private let rememberCheckbox = NSButton(checkboxWithTitle: L10n.t(.rememberPassword), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: L10n.t(.connect), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t(.cancel), target: nil, action: nil)

    private var connecting = false
    private var connectToken = 0
    private let store = SMBConnectionStore.shared

    /// 语言切换重刷绑定：闭包捕获控件 + key，刷新时按当前语言重算 t() 回写。
    private var localizedBindings: [() -> Void] = []
    private func bind(_ field: NSTextField, _ key: L10nKey) {
        localizedBindings.append { field.stringValue = L10n.t(key) }
    }
    private func bind(_ button: NSButton, _ key: L10nKey) {
        localizedBindings.append { button.title = L10n.t(key) }
    }

    /// 语言变更后重刷本窗静态标签（行标签/复选/按钮）。状态文本随流程覆盖，不绑定。
    /// 视图未加载时绑定表为空 → 无操作，不强行 loadView。
    func refreshLocalizedText() {
        localizedBindings.forEach { $0() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))

        let serverRow = row(.fieldServer, serverField)
        let shareRow = row(.fieldShare, shareField)
        let domainRow = row(.fieldDomain, domainField)          // 可选
        let userRow = row(.fieldUser, userField)
        let passwordRow = row(.fieldPassword, passwordField)

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.keyEquivalentModifierMask = []
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let buttonRow = NSStackView(views: [connectButton, cancelButton])
        buttonRow.spacing = 8

        let stack = NSStackView(views: [serverRow, shareRow, domainRow, userRow,
                                        passwordRow, rememberCheckbox, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false   // reduced-SDK 铁律：顶层 stack 漏设 → 窗塌 0 宽
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        // AX 标识（UI 测试定位用）
        serverField.setAccessibilityIdentifier("serverField")
        shareField.setAccessibilityIdentifier("shareField")
        domainField.setAccessibilityIdentifier("domainField")
        userField.setAccessibilityIdentifier("userField")
        passwordField.setAccessibilityIdentifier("passwordField")
        rememberCheckbox.setAccessibilityIdentifier("rememberCheckbox")
        connectButton.setAccessibilityIdentifier("smbConnectButton")
        statusLabel.setAccessibilityIdentifier("smbConnectStatus")

        // 静态标签绑定（复选/按钮标题——属性初始化时冻结，须显式重刷）。
        bind(rememberCheckbox, .rememberPassword)
        bind(connectButton, .connect)
        bind(cancelButton, .cancel)

        view = container
    }

    /// 标签行：左标签（以 key 绑定供语言重刷）+ 右输入框。字段必设 translatesAutoresizingMaskIntoConstraints = false。
    private func row(_ key: L10nKey, _ field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: L10n.t(key))
        bind(label, key)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let r = NSStackView(views: [label, field])
        r.spacing = 8
        return r
    }

    // MARK: - Public

    /// 命令栏 `smb server[/share] [user]` 预填（prepare 之后调用，覆盖最近连接回填）。
    func prefill(server: String?, share: String? = nil, username: String? = nil) {
        if let server, !server.isEmpty { serverField.stringValue = server }
        if let share { shareField.stringValue = share }
        if let username { userField.stringValue = username }
    }

    /// 重置表单并预填最近连接（若有记住的凭据则回填密码并勾选"记住"）；使在途连接结果失效（token++）。
    func prepare() {
        connectToken &+= 1
        connecting = false
        statusLabel.stringValue = ""
        connectButton.isEnabled = true
        if let recent = store.recentConnections.first {
            serverField.stringValue = recent.server
            shareField.stringValue = recent.share
            domainField.stringValue = recent.domain ?? ""
            userField.stringValue = recent.username
            if recent.remembers, let secret = (try? store.loadSecret(for: recent)) ?? nil {
                passwordField.stringValue = secret
                rememberCheckbox.state = .on
            } else {
                passwordField.stringValue = ""
                rememberCheckbox.state = .off
            }
        } else {
            serverField.stringValue = ""; shareField.stringValue = ""
            domainField.stringValue = ""; userField.stringValue = ""; passwordField.stringValue = ""
            rememberCheckbox.state = .off
        }
    }

    /// 聚焦服务器输入框。窗口须已就位（window 为 nil 时 makeFirstResponder 无效）。
    func focusServerField() { view.window?.makeFirstResponder(serverField) }

    // MARK: - Actions

    @objc private func cancelTapped() { view.window?.close() }

    @objc private func connectTapped() {
        guard !connecting else { return }
        let server = serverField.stringValue.trimmingCharacters(in: .whitespaces)
        let share = shareField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !server.isEmpty, !share.isEmpty else {
            statusLabel.stringValue = L10n.t(.fillServerShare)
            return
        }
        let domain = domainField.stringValue.trimmingCharacters(in: .whitespaces)
        let username = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let secret = passwordField.stringValue
        let request = SMBConnectionRequest(server: server, share: share,
                                           domain: domain.isEmpty ? nil : domain,
                                           username: username,
                                           secret: secret.isEmpty ? nil : secret,
                                           remember: rememberCheckbox.state == .on)
        connecting = true
        connectButton.isEnabled = false
        statusLabel.stringValue = L10n.t(.connecting)
        let store = self.store
        let onConnected = self.onConnected
        let token = connectToken
        // mount 同步阻塞（可达数秒）→ 后台队列（global 系统预建，reduced-SDK 安全）。
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(SMBSource, TCPath), Error>
            do { result = .success(try store.connect(request)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard token == self.connectToken else { return }   // 表单已重置/窗口已重开
                self.connecting = false
                self.connectButton.isEnabled = true
                switch result {
                case .success((let source, let home)):
                    self.view.window?.close()
                    onConnected?(source, home)
                case .failure(let error):
                    let message = (error as? TCError).map(tcErrorDisplay) ?? error.localizedDescription
                    self.statusLabel.stringValue = L10n.t(.connectFailedPrefix) + message
                }
            }
        }
    }
}
