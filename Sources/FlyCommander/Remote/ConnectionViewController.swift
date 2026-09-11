import AppKit
import TCCore

final class ConnectionViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onConnected: ((SFTPSource, String) -> Void)?

    // MARK: - 存储 / 连接执行注入

    var store = ConnectionStore.shared

    /// 连接执行注入（SMBConnectionViewController 同款）：completion 须回主线程。
    /// 默认=后台 global 队列 + shared store 真连（原 connectTapped 合同原样搬移）；
    /// 真窗单测替换成同步 fake，UITest 无需真 sshd。
    var connectExecutor: (ConnectionRequest, @escaping (Result<(SFTPSource, home: String), Error>) -> Void) -> Void = { request, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(SFTPSource, home: String), Error>
            do { result = .success(try ConnectionStore.shared.connect(request)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 表单控件

    private let nameField = NSTextField(frame: .zero)
    private let hostField = NSTextField(frame: .zero)
    private let portField = NSTextField(frame: .zero)
    private let userField = NSTextField(frame: .zero)
    private let passwordRadio = NSButton(radioButtonWithTitle: L10n.t(.fieldPassword), target: nil, action: nil)
    private let keyRadio = NSButton(radioButtonWithTitle: L10n.t(.fieldKeyFile), target: nil, action: nil)
    private let passwordField = NSSecureTextField(frame: .zero)
    private let keyPathField = NSTextField(frame: .zero)
    private let browseButton = NSButton(title: L10n.t(.browse), target: nil, action: nil)
    private let passphraseField = NSSecureTextField(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L10n.t(.saveConnection), target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.t(.deleteConnection), target: nil, action: nil)
    private let connectButton = NSButton(title: L10n.t(.connect), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t(.cancel), target: nil, action: nil)

    private var passwordRow: NSStackView!
    private var keyPathRow: NSStackView!
    private var passphraseRow: NSStackView!
    private var connecting = false
    private var connectToken = 0

    // MARK: - 已保存列表区（常显：空列表=占位文案，窗高恒定无动态伸缩）
    private let savedTitleLabel = NSTextField(labelWithString: L10n.t(.savedConnectionsTitle))
    /// internal 供 @testable 真窗锁程序化选中/触发 onActivate（单击载入/双击直连两路）。
    let savedTable = HitTableView()
    private let savedEmptyLabel = NSTextField(labelWithString: L10n.t(.savedListEmpty))
    private let savedScroll = NSScrollView()

    private var records: [SFTPConnectionRecord] = []
    private var selectedRecordID: String?

    /// 语言切换重刷绑定：闭包捕获控件 + key，刷新时按当前语言重算 t() 回写。
    private var localizedBindings: [() -> Void] = []
    private func bind(_ field: NSTextField, _ key: L10nKey) {
        localizedBindings.append { field.stringValue = L10n.t(key) }
    }
    private func bind(_ button: NSButton, _ key: L10nKey) {
        localizedBindings.append { button.title = L10n.t(key) }
    }

    /// 语言变更后重刷本窗静态标签（行标签/单选/区题/空态/按钮）。状态文本随流程覆盖，不绑定。
    /// 视图未加载时绑定表为空 → 无操作，不强行 loadView。
    func refreshLocalizedText() {
        localizedBindings.forEach { $0() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))

        let nameRow = row(.fieldConnName, nameField)
        let hostRow = row(.fieldHost, hostField)
        let netRow = NSStackView(views: [
            labeled(.fieldPort, portField, width: 60),
            labeled(.fieldUser, userField),
        ])
        netRow.spacing = 16

        let radioRow = NSStackView(views: [passwordRadio, keyRadio])
        radioRow.spacing = 20

        passwordRow = labeled(.fieldPassword, passwordField)
        keyPathRow = row(.fieldKey, keyPathField)
        keyPathRow.addArrangedSubview(browseButton)
        passphraseRow = labeled(.fieldPassphrase, passphraseField)
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
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isEnabled = false
        passwordRadio.target = self
        passwordRadio.action = #selector(authRadioChanged)
        keyRadio.target = self
        keyRadio.action = #selector(authRadioChanged)
        passwordRadio.state = .on

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor

        let buttonRow = NSStackView(views: [connectButton, cancelButton, saveButton, deleteButton])
        buttonRow.spacing = 8

        // 列表区：固定 110 高容器内 scroll+表格 与 空态占位 互斥显隐 → 窗高只 autogrow 一次。
        savedTitleLabel.font = .systemFont(ofSize: 11)
        savedTitleLabel.textColor = .secondaryLabelColor
        savedEmptyLabel.font = .systemFont(ofSize: 11)
        savedEmptyLabel.textColor = .tertiaryLabelColor
        savedEmptyLabel.alignment = .center
        savedEmptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("connName"))
        column.width = 420
        savedTable.addTableColumn(column)
        savedTable.headerView = nil
        savedTable.rowHeight = 18
        savedTable.dataSource = self
        savedTable.delegate = self
        savedTable.onActivate = { [weak self] in self?.connectSelected() }

        savedScroll.documentView = savedTable
        savedScroll.hasVerticalScroller = true
        savedScroll.borderType = .bezelBorder
        savedScroll.translatesAutoresizingMaskIntoConstraints = false

        let listBox = NSView()
        listBox.translatesAutoresizingMaskIntoConstraints = false
        listBox.addSubview(savedScroll)
        listBox.addSubview(savedEmptyLabel)
        NSLayoutConstraint.activate([
            listBox.heightAnchor.constraint(equalToConstant: 110),
            savedScroll.topAnchor.constraint(equalTo: listBox.topAnchor),
            savedScroll.bottomAnchor.constraint(equalTo: listBox.bottomAnchor),
            savedScroll.leadingAnchor.constraint(equalTo: listBox.leadingAnchor),
            savedScroll.trailingAnchor.constraint(equalTo: listBox.trailingAnchor),
            savedEmptyLabel.centerXAnchor.constraint(equalTo: listBox.centerXAnchor),
            savedEmptyLabel.centerYAnchor.constraint(equalTo: listBox.centerYAnchor),
        ])

        let stack = NSStackView(views: [nameRow, hostRow, netRow, radioRow, passwordRow,
                                        keyPathRow, passphraseRow, statusLabel,
                                        savedTitleLabel, listBox, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -40),
            // bottom 必须钉死 → 窗口经 contentViewController 按内容 autogrow。
            // 列表区使内容远超 init 的 300 高：缺这条 Connect/Cancel 底缘被裁
            // （对齐 SMB 窗现状；前轮「SFTP 不修」前提被本功能推翻）。
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        // AX 标识（UI 测试定位用）
        nameField.setAccessibilityIdentifier("nameField")
        hostField.setAccessibilityIdentifier("hostField")
        portField.setAccessibilityIdentifier("portField")
        userField.setAccessibilityIdentifier("userField")
        passwordField.setAccessibilityIdentifier("passwordField")
        keyPathField.setAccessibilityIdentifier("keyPathField")
        passphraseField.setAccessibilityIdentifier("passphraseField")
        saveButton.setAccessibilityIdentifier("saveConnectionButton")
        deleteButton.setAccessibilityIdentifier("deleteConnectionButton")
        savedTable.setAccessibilityIdentifier("savedTable")
        connectButton.setAccessibilityIdentifier("connectButton")
        statusLabel.setAccessibilityIdentifier("connectStatus")

        // 静态标签绑定（单选/按钮/区题/空态——属性初始化时冻结，须显式重刷）。
        bind(passwordRadio, .fieldPassword)
        bind(keyRadio, .fieldKeyFile)
        bind(browseButton, .browse)
        bind(saveButton, .saveConnection)
        bind(deleteButton, .deleteConnection)
        bind(savedTitleLabel, .savedConnectionsTitle)
        bind(savedEmptyLabel, .savedListEmpty)
        bind(connectButton, .connect)
        bind(cancelButton, .cancel)

        view = container
    }

    /// 标签行（左标签 + 输入框）：标签以 key 绑定，供语言切换重刷。
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

    private func labeled(_ key: L10nKey, _ field: NSTextField, width: CGFloat? = nil) -> NSStackView {
        let r = row(key, field)
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return r
    }

    // MARK: - Public

    /// 命令栏 `sftp host[:port]` 预填（prepare 之后调用）。
    func prefillHost(_ host: String) { hostField.stringValue = host }
    func prefillPort(_ port: UInt16) { portField.stringValue = String(port) }

    /// 重置表单（不回填任何条目——「单击即编辑」语义由列表选中载入承担）+ 刷新列表；
    /// 使在途连接结果失效（token++）。
    func prepare() {
        connectToken &+= 1
        connecting = false
        statusLabel.stringValue = ""
        connectButton.isEnabled = true
        nameField.stringValue = ""
        hostField.stringValue = ""
        portField.stringValue = "22"
        userField.stringValue = ""
        keyPathField.stringValue = ""
        passwordField.stringValue = ""
        passphraseField.stringValue = ""
        setAuth(.password)
        refreshSavedList()
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

    // MARK: - 已保存列表

    private func rowText(_ rec: SFTPConnectionRecord) -> String {
        rec.name.isEmpty ? rec.paramsSummary : "\(rec.name) (\(rec.paramsSummary))"
    }

    private func refreshSavedList() {
        records = store.savedConnections
        savedScroll.isHidden = records.isEmpty
        savedEmptyLabel.isHidden = !records.isEmpty
        selectedRecordID = nil
        deleteButton.isEnabled = false
        savedTable.deselectAll(nil)
        savedTable.reloadData()
    }

    private func selectedRecord() -> SFTPConnectionRecord? {
        let row = savedTable.selectedRow
        guard row >= 0, row < records.count else { return nil }
        return records[row]
    }

    /// 单击载入：选中行参数回填表单（含 Keychain secret 回读），可改后再保存/连接。
    private func loadRecordIntoForm(_ rec: SFTPConnectionRecord) {
        nameField.stringValue = rec.name
        hostField.stringValue = rec.host
        portField.stringValue = String(rec.port)
        userField.stringValue = rec.username
        keyPathField.stringValue = rec.keyPath ?? ""
        setAuth(rec.auth)
        let secret = rec.remembers ? ((try? store.loadSecret(for: rec)) ?? nil) ?? "" : ""
        fillSecret(secret)
    }

    /// 双击/Return：以存好的参数+密钥立即连接（成败都不写列表）。
    private func connectSelected() {
        guard let rec = selectedRecord() else { return }
        let secret = rec.remembers ? ((try? store.loadSecret(for: rec)) ?? nil) : nil
        let request = ConnectionRequest(host: rec.host, port: rec.port, username: rec.username,
                                        auth: rec.auth, keyPath: rec.keyPath, secret: secret)
        runConnect(request)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("connNameCell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {   // 本 SDK 无 registerClass——makeView 恒 nil，手动建
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 11)
            tf.lineBreakMode = .byTruncatingTail
            let c = NSTableCellView()
            c.addSubview(tf)
            c.textField = tf
            tf.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            c.identifier = id
            cell = c
        }
        cell?.textField?.stringValue = rowText(records[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let rec = selectedRecord() else {
            selectedRecordID = nil
            deleteButton.isEnabled = false
            return
        }
        selectedRecordID = rec.id
        deleteButton.isEnabled = true
        loadRecordIntoForm(rec)
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

    @objc private func saveTapped() {
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
        let isKey = keyRadio.state == .on
        let keyPath = keyPathField.stringValue.trimmingCharacters(in: .whitespaces)
        if isKey && keyPath.isEmpty {
            statusLabel.stringValue = L10n.t(.chooseKeyFile)
            return
        }
        let secret = isKey ? passphraseField.stringValue : passwordField.stringValue
        let record = SFTPConnectionRecord(
            name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
            id: selectedRecordID ?? UUID().uuidString,
            host: host, port: port,
            username: userField.stringValue.trimmingCharacters(in: .whitespaces),
            auth: isKey ? .keyFile : .password,
            keyPath: isKey ? keyPath : nil)
        do {
            _ = try store.save(record, secret: secret.isEmpty ? nil : secret)
            statusLabel.stringValue = L10n.t(.savedDone)
        } catch ConnectionStore.SaveError.listFull {
            statusLabel.stringValue = L10n.t(.savedListFull)
        } catch ConnectionStore.SaveError.sameNameExists {
            let alert = NSAlert()
            alert.messageText = L10n.t(.savedDuplicateTitle)
            alert.informativeText = L10n.t(.savedDuplicateBody)
            alert.addButton(withTitle: L10n.t(.okBtn))
            alert.addButton(withTitle: L10n.t(.cancelBtn))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                _ = try store.save(record, secret: secret.isEmpty ? nil : secret, force: true)
                statusLabel.stringValue = L10n.t(.savedDone)
            } catch ConnectionStore.SaveError.listFull {
                statusLabel.stringValue = L10n.t(.savedListFull)
                refreshSavedList()
                return
            } catch {}
        } catch {}
        refreshSavedList()
    }

    @objc private func deleteTapped() {
        guard let id = selectedRecordID else { return }
        store.remove(id: id)
        refreshSavedList()
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
            secret: secret.isEmpty ? nil : secret)
        runConnect(request)
    }

    /// 连接执行公共段：token/连接中/失败态合同（原 connectTapped 内联逻辑抽出，
    /// 供表单 Connect 与列表双击两路复用）。
    private func runConnect(_ request: ConnectionRequest) {
        guard !connecting else { return }
        connecting = true
        connectButton.isEnabled = false
        statusLabel.stringValue = L10n.t(.connecting)
        let onConnected = self.onConnected
        let token = connectToken
        connectExecutor(request) { [weak self] result in
            guard let self, token == self.connectToken else { return }   // 表单已重置/窗口已重开
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
