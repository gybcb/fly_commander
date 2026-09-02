import AppKit
import TCCore

final class ConnectionViewController: NSViewController {
    var onConnected: ((SFTPSource, String) -> Void)?

    // MARK: - 表单控件

    private let hostField = NSTextField(frame: .zero)
    private let portField = NSTextField(frame: .zero)
    private let userField = NSTextField(frame: .zero)
    private let passwordRadio = NSButton(radioButtonWithTitle: L10n.t(.fieldPassword), target: nil, action: nil)
    private let keyRadio = NSButton(radioButtonWithTitle: L10n.t(.fieldKeyFile), target: nil, action: nil)
    private let passwordField = NSSecureTextField(frame: .zero)
    private let keyPathField = NSTextField(frame: .zero)
    private let browseButton = NSButton(title: L10n.t(.browse), target: nil, action: nil)
    private let passphraseField = NSSecureTextField(frame: .zero)
    private let rememberCheckbox = NSButton(checkboxWithTitle: L10n.t(.rememberPassword), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: L10n.t(.connect), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t(.cancel), target: nil, action: nil)

    private var passwordRow: NSStackView!
    private var keyPathRow: NSStackView!
    private var passphraseRow: NSStackView!
    private var connecting = false
    private var connectToken = 0

    private let store = ConnectionStore.shared

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

        let hostRow = row(L10n.t(.fieldHost), hostField)
        let netRow = NSStackView(views: [
            labeled(L10n.t(.fieldPort), portField, width: 60),
            labeled(L10n.t(.fieldUser), userField),
        ])
        netRow.spacing = 16

        let radioRow = NSStackView(views: [passwordRadio, keyRadio])
        radioRow.spacing = 20

        passwordRow = labeled(L10n.t(.fieldPassword), passwordField)
        keyPathRow = row(L10n.t(.fieldKey), keyPathField)
        keyPathRow.addArrangedSubview(browseButton)
        passphraseRow = labeled(L10n.t(.fieldPassphrase), passphraseField)
        passwordRow.isHidden = false
        keyPathRow.isHidden = true
        passphraseRow.isHidden = true

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
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseTapped)
        passwordRadio.target = self
        passwordRadio.action = #selector(authRadioChanged)
        keyRadio.target = self
        keyRadio.action = #selector(authRadioChanged)
        passwordRadio.state = .on

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let buttonRow = NSStackView(views: [connectButton, cancelButton])
        buttonRow.spacing = 8

        let stack = NSStackView(views: [hostRow, netRow, radioRow, passwordRow,
                                        keyPathRow, passphraseRow,
                                        rememberCheckbox, statusLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        // AX 标识（UI 测试定位用）
        hostField.setAccessibilityIdentifier("hostField")
        portField.setAccessibilityIdentifier("portField")
        userField.setAccessibilityIdentifier("userField")
        passwordField.setAccessibilityIdentifier("passwordField")
        keyPathField.setAccessibilityIdentifier("keyPathField")
        passphraseField.setAccessibilityIdentifier("passphraseField")
        rememberCheckbox.setAccessibilityIdentifier("rememberCheckbox")
        connectButton.setAccessibilityIdentifier("connectButton")
        statusLabel.setAccessibilityIdentifier("connectStatus")

        view = container
    }

    private func row(_ title: String, _ field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let r = NSStackView(views: [label, field])
        r.spacing = 8
        return r
    }

    private func labeled(_ title: String, _ field: NSTextField, width: CGFloat? = nil) -> NSStackView {
        let r = row(title, field)
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return r
    }

    // MARK: - Public

    /// 命令栏 `sftp host[:port]` 预填（prepare 之后调用，覆盖最近连接回填）。
    func prefillHost(_ host: String) { hostField.stringValue = host }
    func prefillPort(_ port: UInt16) { portField.stringValue = String(port) }

    /// 重置表单并预填最近连接（若有记住的凭据则回填并勾选"记住"）。
    /// 使在途连接结果失效（token++）。
    func prepare() {
        connectToken &+= 1
        connecting = false
        statusLabel.stringValue = ""
        connectButton.isEnabled = true
        if let recent = store.recentConnections.first {
            hostField.stringValue = recent.host
            portField.stringValue = String(recent.port)
            userField.stringValue = recent.username
            keyPathField.stringValue = recent.keyPath ?? ""
            setAuth(recent.auth)
            if recent.remembers, let secret = (try? store.loadSecret(for: recent)) ?? nil {
                fillSecret(secret)
                rememberCheckbox.state = .on
            } else {
                rememberCheckbox.state = .off
            }
        } else {
            hostField.stringValue = ""
            portField.stringValue = "22"
            userField.stringValue = ""
            keyPathField.stringValue = ""
            passwordField.stringValue = ""
            passphraseField.stringValue = ""
            setAuth(.password)
            rememberCheckbox.state = .off
        }
    }

    /// 聚焦主机输入框。窗口须已就位（window 为 nil 时 makeFirstResponder 无效）。
    func focusHostField() {
        view.window?.makeFirstResponder(hostField)
    }

    private func setAuth(_ kind: SFTPConnectionRecord.AuthKind) {
        switch kind {
        case .password:
            passwordRadio.state = .on
            keyRadio.state = .off
            passwordRow.isHidden = false
            keyPathRow.isHidden = true
            passphraseRow.isHidden = true
        case .keyFile:
            keyRadio.state = .on
            passwordRadio.state = .off
            passwordRow.isHidden = true
            keyPathRow.isHidden = false
            passphraseRow.isHidden = false
        }
    }

    private func fillSecret(_ secret: String) {
        if passwordRow.isHidden { passphraseField.stringValue = secret }
        else { passwordField.stringValue = secret }
    }

    // MARK: - Actions

    @objc private func authRadioChanged() {
        setAuth(keyRadio.state == .on ? .keyFile : .password)
    }

    @objc private func browseTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t(.chooseWord)
        if panel.runModal() == .OK, let url = panel.url {
            keyPathField.stringValue = url.path
        }
    }

    @objc private func cancelTapped() {
        view.window?.close()
    }

    @objc private func connectTapped() {
        guard !connecting else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            statusLabel.stringValue = L10n.t(.fillHost)
            return
        }
        guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces)),
              port > 0 else {
            statusLabel.stringValue = L10n.t(.invalidPort)
            return
        }
        let username = userField.stringValue.trimmingCharacters(in: .whitespaces)
        let isKey = keyRadio.state == .on
        let secret = (isKey ? passphraseField.stringValue : passwordField.stringValue)
        let keyPath = keyPathField.stringValue.trimmingCharacters(in: .whitespaces)
        if isKey && keyPath.isEmpty {
            statusLabel.stringValue = L10n.t(.chooseKeyFile)
            return
        }
        let request = ConnectionRequest(
            host: host, port: port, username: username,
            auth: isKey ? .keyFile : .password,
            keyPath: isKey ? keyPath : nil,
            secret: secret.isEmpty ? nil : secret,
            remember: rememberCheckbox.state == .on)

        connecting = true
        connectButton.isEnabled = false
        statusLabel.stringValue = L10n.t(.connecting)

        // SSH 握手同步阻塞——后台队列执行（global 队列为系统预建，本工具链安全）。
        let store = self.store
        let onConnected = self.onConnected
        let token = connectToken
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(SFTPSource, home: String), Error>
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
                    let message = (error as? TCError)?.message ?? error.localizedDescription
                    self.statusLabel.stringValue = L10n.t(.connectFailedPrefix) + message
                }
            }
        }
    }
}
