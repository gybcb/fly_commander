import AppKit
import TCCore

final class SMBConnectionViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onConnected: ((SMBSource, TCPath) -> Void)?

    // MARK: - 存储 / 连接执行注入

    var store = SMBConnectionStore.shared

    /// 连接执行注入（TransferEngine runInBackground/onMain 注入先例）：
    /// completion 须回主线程。默认=后台 global 队列 + shared store 真连
    /// （原 connectTapped 合同原样搬移）；真窗单测替换成同步 fake，UITest 无需真挂载。
    var connectExecutor: (SMBConnectionRequest, @escaping (Result<(SMBSource, TCPath), Error>) -> Void) -> Void = { request, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(SMBSource, TCPath), Error>
            do { result = .success(try SMBConnectionStore.shared.connect(request)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 表单控件
    private let nameField = NSTextField(frame: .zero)
    private let serverField = NSTextField(frame: .zero)
    private let shareField = NSTextField(frame: .zero)
    private let domainField = NSTextField(frame: .zero)
    private let userField = NSTextField(frame: .zero)
    private let passwordField = NSSecureTextField(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L10n.t(.saveConnection), target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.t(.deleteConnection), target: nil, action: nil)
    private let connectButton = NSButton(title: L10n.t(.connect), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t(.cancel), target: nil, action: nil)

    // MARK: - 已保存列表区（常显：空列表=占位文案，窗高恒定无动态伸缩）
    private let savedTitleLabel = NSTextField(labelWithString: L10n.t(.savedConnectionsTitle))
    /// internal 供 @testable 真窗锁程序化选中/触发 onActivate（单击载入/双击直连两路）。
    let savedTable = HitTableView()
    private let savedEmptyLabel = NSTextField(labelWithString: L10n.t(.savedListEmpty))
    private let savedScroll = NSScrollView()

    private var records: [SMBConnectionRecord] = []
    private var selectedRecordID: String?

    private var connecting = false
    private var connectToken = 0

    /// 语言切换重刷绑定：闭包捕获控件 + key，刷新时按当前语言重算 t() 回写。
    private var localizedBindings: [() -> Void] = []
    private func bind(_ field: NSTextField, _ key: L10nKey) {
        localizedBindings.append { field.stringValue = L10n.t(key) }
    }
    private func bind(_ button: NSButton, _ key: L10nKey) {
        localizedBindings.append { button.title = L10n.t(key) }
    }

    /// 语言变更后重刷本窗静态标签（行标签/区题/空态/按钮）。状态文本随流程覆盖，不绑定。
    /// 视图未加载时绑定表为空 → 无操作，不强行 loadView。
    func refreshLocalizedText() {
        localizedBindings.forEach { $0() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))

        let nameRow = row(.fieldConnName, nameField)
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
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isEnabled = false

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

        let stack = NSStackView(views: [nameRow, serverRow, shareRow, domainRow, userRow,
                                        passwordRow, statusLabel, savedTitleLabel, listBox, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false   // reduced-SDK 铁律：顶层 stack 漏设 → 窗塌 0 宽
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -40),
            // bottom 必须钉死 → 窗口经 contentViewController 按内容 autogrow。
            // 缺这条时窗高恒等于 contentRect 初值，列表加入后内容远超初值
            // → Connect/Cancel 底缘越出窗口底被裁（原 8 行被裁事故同因）。
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        // AX 标识（UI 测试定位用）
        nameField.setAccessibilityIdentifier("nameField")
        serverField.setAccessibilityIdentifier("serverField")
        shareField.setAccessibilityIdentifier("shareField")
        domainField.setAccessibilityIdentifier("domainField")
        userField.setAccessibilityIdentifier("userField")
        passwordField.setAccessibilityIdentifier("passwordField")
        saveButton.setAccessibilityIdentifier("saveConnectionButton")
        deleteButton.setAccessibilityIdentifier("deleteConnectionButton")
        savedTable.setAccessibilityIdentifier("savedTable")
        connectButton.setAccessibilityIdentifier("smbConnectButton")
        statusLabel.setAccessibilityIdentifier("smbConnectStatus")

        // 静态标签绑定（按钮/区题/空态——属性初始化时冻结，须显式重刷）。
        bind(saveButton, .saveConnection)
        bind(deleteButton, .deleteConnection)
        bind(savedTitleLabel, .savedConnectionsTitle)
        bind(savedEmptyLabel, .savedListEmpty)
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

    /// 命令栏 `smb server[/share] [user]` 预填（prepare 之后调用）。
    func prefill(server: String?, share: String? = nil, username: String? = nil) {
        if let server, !server.isEmpty { serverField.stringValue = server }
        if let share { shareField.stringValue = share }
        if let username { userField.stringValue = username }
    }

    /// 重置表单（不回填任何条目——「单击即编辑」语义由列表选中载入承担）+ 刷新列表；
    /// 使在途连接结果失效（token++）。
    func prepare() {
        connectToken &+= 1
        connecting = false
        statusLabel.stringValue = ""
        connectButton.isEnabled = true
        nameField.stringValue = ""
        serverField.stringValue = ""
        shareField.stringValue = ""
        domainField.stringValue = ""
        userField.stringValue = ""
        passwordField.stringValue = ""
        refreshSavedList()
    }

    /// 聚焦服务器输入框。窗口须已就位（window 为 nil 时 makeFirstResponder 无效）。
    func focusServerField() { view.window?.makeFirstResponder(serverField) }

    // MARK: - 已保存列表

    private func rowText(_ rec: SMBConnectionRecord) -> String {
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

    private func selectedRecord() -> SMBConnectionRecord? {
        let row = savedTable.selectedRow
        guard row >= 0, row < records.count else { return nil }
        return records[row]
    }

    /// 单击载入：选中行参数回填表单（含 Keychain 密码回读），可改后再保存/连接。
    private func loadRecordIntoForm(_ rec: SMBConnectionRecord) {
        nameField.stringValue = rec.name
        serverField.stringValue = rec.server
        shareField.stringValue = rec.share
        domainField.stringValue = rec.domain ?? ""
        userField.stringValue = rec.username
        passwordField.stringValue = rec.remembers ? ((try? store.loadSecret(for: rec)) ?? nil) ?? "" : ""
    }

    /// 双击/Return：以存好的参数+密钥立即连接（成败都不写列表）。
    private func connectSelected() {
        guard let rec = selectedRecord() else { return }
        let secret = rec.remembers ? ((try? store.loadSecret(for: rec)) ?? nil) : nil
        let request = SMBConnectionRequest(server: rec.server, share: rec.share,
                                           domain: rec.domain, username: rec.username,
                                           secret: secret)
        runConnect(request)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("connNameCell")
        var cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {   // 本 SDK 无 registerClass——makeView 恒 nil，手动建（FileCellView 同款回退）
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

    @objc private func cancelTapped() { view.window?.close() }

    @objc private func saveTapped() {
        let server = serverField.stringValue.trimmingCharacters(in: .whitespaces)
        let share = shareField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !server.isEmpty, !share.isEmpty else {
            statusLabel.stringValue = L10n.t(.fillServerShare)
            return
        }
        let domain = domainField.stringValue.trimmingCharacters(in: .whitespaces)
        let record = SMBConnectionRecord(name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                                         id: selectedRecordID ?? UUID().uuidString,
                                         server: server, share: share,
                                         domain: domain.isEmpty ? nil : domain,
                                         username: userField.stringValue.trimmingCharacters(in: .whitespaces))
        let secret = passwordField.stringValue
        do {
            _ = try store.save(record, secret: secret.isEmpty ? nil : secret)
            statusLabel.stringValue = L10n.t(.savedDone)
        } catch SMBConnectionStore.SaveError.listFull {
            statusLabel.stringValue = L10n.t(.savedListFull)
        } catch SMBConnectionStore.SaveError.sameNameExists {
            let alert = NSAlert()
            alert.messageText = L10n.t(.savedDuplicateTitle)
            alert.informativeText = L10n.t(.savedDuplicateBody)
            alert.addButton(withTitle: L10n.t(.okBtn))
            alert.addButton(withTitle: L10n.t(.cancelBtn))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                _ = try store.save(record, secret: secret.isEmpty ? nil : secret, force: true)
                statusLabel.stringValue = L10n.t(.savedDone)
            } catch SMBConnectionStore.SaveError.listFull {
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
                                           secret: secret.isEmpty ? nil : secret)
        runConnect(request)
    }

    /// 连接执行公共段：token/连接中/失败态合同（原 connectTapped 内联逻辑抽出，
    /// 供表单 Connect 与列表双击两路复用）。
    private func runConnect(_ request: SMBConnectionRequest) {
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
