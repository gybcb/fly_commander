import AppKit
import TCCore

/// 统一「连接到远端」对话框（SFTP / SMB / FTP 三协议一窗，顶部段控件互斥切换）。
///
/// 取代 ConnectionViewController（SFTP）与 SMBConnectionViewController（两者 90% 同构）：
/// 公共行=名称 / 主机或服务器 / 端口（仅 sftp/ftp）/ 用户 / 密码 / 域（仅 smb）/ 共享（仅 smb），
/// 协议专有行=SFTP 的认证方式单选 + 密钥路径 + 口令行、FTP 的 TLS 勾选。
///
/// 语义合同逐字沿用旧两 VC：保存/删除/单击回填/双击直连/token 防竞态/语言绑定/空态常显。
///
/// 执行器注入：`executors` 按协议查表，缺 key → 状态行提示未接线（**FTP 的注入缝**：
/// 协议层由并行任务实现，此处不引用任何 FTP 类型）。completion 须回主线程
/// （TransferEngine runInBackground/onMain 注入先例）；默认=后台 global 队列 + 真连，
/// 真窗单测替换成同步 fake → 无需真 sshd / 真挂载。
final class RemoteConnectionViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// 连接成功回调：(远端数据源, 起始路径)。
    var onConnected: ((any FileSource, TCPath) -> Void)?

    var store = RemoteConnectionStore.shared

    /// 按协议注入的执行器表。缺 key → 状态行提示未接线，不静默失败。
    /// 生产接线在 MainViewController（注入 `RemoteConnectExecutors.defaults`，含 SFTP
    /// 的 home:String→TCPath 转换——转换归接线方，不在 VC）；真窗单测注入同步 fake。
    var executors: [RemoteProto: RemoteConnectExecutor] = [:]

    /// 当前协议（段控件选中）。
    private(set) var proto: RemoteProto = .sftp

    // MARK: - 表单控件
    private let protoSegment = NSSegmentedControl(labels: RemoteProto.allLabels,
                                                  trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let nameField = NSTextField(frame: .zero)
    private let hostField = NSTextField(frame: .zero)
    private let serverField = NSTextField(frame: .zero)
    private let shareField = NSTextField(frame: .zero)
    private let domainField = NSTextField(frame: .zero)
    private let portField = NSTextField(frame: .zero)
    private let userField = NSTextField(frame: .zero)
    private let passwordField = NSSecureTextField(frame: .zero)
    private let passwordRadio = NSButton(radioButtonWithTitle: L10n.t(.fieldPassword), target: nil, action: nil)
    private let keyRadio = NSButton(radioButtonWithTitle: L10n.t(.fieldKeyFile), target: nil, action: nil)
    private let keyPathField = NSTextField(frame: .zero)
    private let browseButton = NSButton(title: L10n.t(.browse), target: nil, action: nil)
    private let passphraseField = NSSecureTextField(frame: .zero)
    private let tlsCheckbox = NSButton(checkboxWithTitle: L10n.t(.fieldTLS), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L10n.t(.saveConnection), target: nil, action: nil)
    private let deleteButton = NSButton(title: L10n.t(.deleteConnection), target: nil, action: nil)
    private let connectButton = NSButton(title: L10n.t(.connect), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t(.cancel), target: nil, action: nil)

    // 行容器（协议字段组互斥显隐即切这些行）
    private var hostRow = NSStackView()
    private var serverRow = NSStackView()
    private var shareRow = NSStackView()
    private var domainRow = NSStackView()
    private var portRow = NSStackView()
    private var authRadioRow = NSStackView()
    private var keyPathRow = NSStackView()
    private var passphraseRow = NSStackView()
    private var tlsRow = NSStackView()

    private var connecting = false
    private var connectToken = 0

    // MARK: - 已保存列表区（常显：空列表=占位文案，窗高恒定无动态伸缩）
    private let savedTitleLabel = NSTextField(labelWithString: L10n.t(.savedConnectionsTitle))
    /// internal 供 @testable 真窗锁程序化选中/触发 onActivate（单击载入/双击直连两路）。
    let savedTable = HitTableView()
    private let savedEmptyLabel = NSTextField(labelWithString: L10n.t(.savedListEmpty))
    private let savedScroll = NSScrollView()

    private var records: [RemoteConnectionRecord] = []
    private var selectedRecordID: String?

    /// 语言切换重刷绑定：闭包捕获控件 + key，刷新时按当前语言重算 t() 回写。
    private var localizedBindings: [() -> Void] = []
    private func bind(_ field: NSTextField, _ key: L10nKey) {
        localizedBindings.append { field.stringValue = L10n.t(key) }
    }
    private func bind(_ button: NSButton, _ key: L10nKey) {
        localizedBindings.append { button.title = L10n.t(key) }
    }

    /// 语言变更后重刷本窗静态标签（协议段/行标签/单选/区题/空态/按钮）。
    /// 状态文本随流程覆盖，不绑定。视图未加载时绑定表为空 → 无操作，不强行 loadView。
    func refreshLocalizedText() {
        localizedBindings.forEach { $0() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))

        protoSegment.target = self
        protoSegment.action = #selector(protoChanged)

        nameRow = row(.fieldConnName, nameField)
        hostRow = row(.fieldHost, hostField)
        serverRow = row(.fieldServer, serverField)
        shareRow = row(.fieldShare, shareField)
        domainRow = row(.fieldDomain, domainField)
        portRow = labeled(.fieldPort, portField, width: 60)
        userRow = row(.fieldUser, userField)
        passwordRow = row(.fieldPassword, passwordField)

        authRadioRow = NSStackView(views: [passwordRadio, keyRadio])
        authRadioRow.spacing = 20
        keyPathRow = row(.fieldKey, keyPathField)
        keyPathRow.addArrangedSubview(browseButton)
        passphraseRow = labeled(.fieldPassphrase, passphraseField)
        tlsRow = NSStackView(views: [tlsCheckbox])

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

        let stack = NSStackView(views: [protoSegment, nameRow, hostRow, serverRow, shareRow,
                                        domainRow, portRow, userRow, passwordRow, authRadioRow,
                                        keyPathRow, passphraseRow, tlsRow, statusLabel,
                                        savedTitleLabel, listBox, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false   // reduced-SDK 铁律：漏设 → 窗塌 0 宽
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -40),
            // bottom 必须钉死 → 窗口经 contentViewController 按内容 autogrow（旧两窗同款教训：
            // 缺这条时窗高恒等于 contentRect 初值，底缘按钮被裁）。
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        // AX 标识（UI 测试定位用；沿用旧两窗的 identifier）
        protoSegment.setAccessibilityIdentifier("protoSegment")
        nameField.setAccessibilityIdentifier("nameField")
        hostField.setAccessibilityIdentifier("hostField")
        serverField.setAccessibilityIdentifier("serverField")
        shareField.setAccessibilityIdentifier("shareField")
        domainField.setAccessibilityIdentifier("domainField")
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

        // 静态标签绑定（协议段/单选/按钮/区题/空态——属性初始化时冻结，须显式重刷）。
        bindProtoSegment()
        bind(passwordRadio, .fieldPassword)
        bind(keyRadio, .fieldKeyFile)
        bind(tlsCheckbox, .fieldTLS)
        bind(browseButton, .browse)
        bind(saveButton, .saveConnection)
        bind(deleteButton, .deleteConnection)
        bind(savedTitleLabel, .savedConnectionsTitle)
        bind(savedEmptyLabel, .savedListEmpty)
        bind(connectButton, .connect)
        bind(cancelButton, .cancel)

        applyProtoVisibility()
        view = container
    }

    private var nameRow = NSStackView()
    private var userRow = NSStackView()
    private var passwordRow = NSStackView()

    /// 协议段三段标签（语言切换重刷；协议专名各语言同值，但沿用绑定机制防将来分化）。
    private func bindProtoSegment() {
        localizedBindings.append {
            for (i, p) in RemoteProto.orderedAll.enumerated() {
                self.protoSegment.setLabel(p.label, forSegment: i)
            }
        }
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

    /// 重置表单（不回填任何条目——「单击即编辑」语义由列表选中载入承担）+ 刷新列表；
    /// 使在途连接结果失效（token++）。
    func prepare() {
        connectToken &+= 1
        connecting = false
        statusLabel.stringValue = ""
        connectButton.isEnabled = true
        nameField.stringValue = ""
        hostField.stringValue = ""
        serverField.stringValue = ""
        shareField.stringValue = ""
        domainField.stringValue = ""
        portField.stringValue = ""
        userField.stringValue = ""
        passwordField.stringValue = ""
        keyPathField.stringValue = ""
        passphraseField.stringValue = ""
        tlsCheckbox.state = .off
        setAuth(.password)
        refreshSavedList()
    }

    /// 设协议（段控件 + 互斥显隐 + 该协议默认端口）。prepare 之后调用（present 顺序合同）。
    func setProto(_ p: RemoteProto) {
        proto = p
        if let i = RemoteProto.orderedAll.firstIndex(of: p) { protoSegment.selectedSegment = i }
        portField.stringValue = String(p.defaultPort)
        applyProtoVisibility()
    }

    /// 预填（prepare/setProto 之后调用；nil 项不动）。
    func prefill(host: String? = nil, port: Int? = nil, server: String? = nil,
                 share: String? = nil, username: String? = nil) {
        if let host, !host.isEmpty { hostField.stringValue = host }
        if let port { portField.stringValue = String(port) }
        if let server, !server.isEmpty { serverField.stringValue = server }
        if let share { shareField.stringValue = share }
        if let username { userField.stringValue = username }
    }

    /// 聚焦当前协议的主输入框。窗口须已就位（window 为 nil 时 makeFirstResponder 无效）。
    func focusPrimaryField() {
        view.window?.makeFirstResponder(proto == .smb ? serverField : hostField)
    }

    // MARK: - 协议显隐

    private func applyProtoVisibility() {
        hostRow.isHidden = proto == .smb
        portRow.isHidden = proto == .smb   // 端口仅 sftp/ftp 有
        serverRow.isHidden = proto != .smb
        shareRow.isHidden = proto != .smb
        domainRow.isHidden = proto != .smb
        authRadioRow.isHidden = proto != .sftp
        keyPathRow.isHidden = proto != .sftp || keyRadio.state != .on
        passphraseRow.isHidden = proto != .sftp || keyRadio.state != .on
        tlsRow.isHidden = proto != .ftp
    }

    private func setAuth(_ kind: SFTPConnectionRecord.AuthKind) {
        switch kind {
        case .password:
            passwordRadio.state = .on
            keyRadio.state = .off
        case .keyFile:
            keyRadio.state = .on
            passwordRadio.state = .off
        }
        applyProtoVisibility()
    }

    /// secret 落哪个框：keyFile 认证（仅 SFTP 有）口令行，否则密码行。
    private func fillSecret(_ secret: String) {
        if proto == .sftp && keyRadio.state == .on { passphraseField.stringValue = secret }
        else { passwordField.stringValue = secret }
    }

    // MARK: - 已保存列表

    private func refreshSavedList() {
        records = store.savedConnections
        savedScroll.isHidden = records.isEmpty
        savedEmptyLabel.isHidden = !records.isEmpty
        selectedRecordID = nil
        deleteButton.isEnabled = false
        savedTable.deselectAll(nil)
        savedTable.reloadData()
    }

    private func selectedRecord() -> RemoteConnectionRecord? {
        let row = savedTable.selectedRow
        guard row >= 0, row < records.count else { return nil }
        return records[row]
    }

    /// 单击载入：整条参数回填表单（含 Keychain secret 回读），并**把表单切到该条目的
    /// 协议**——单表单+段控件的设计下这是「单击即编辑」的前提，否则条目字段与可见字段
    /// 对不上（旧两 VC 各只一协议，无此问题）。
    private func loadRecordIntoForm(_ rec: RemoteConnectionRecord) {
        setProto(rec.proto)
        nameField.stringValue = rec.name
        hostField.stringValue = rec.host ?? ""
        portField.stringValue = rec.port.map(String.init) ?? ""
        serverField.stringValue = rec.server ?? ""
        shareField.stringValue = rec.share ?? ""
        domainField.stringValue = rec.domain ?? ""
        userField.stringValue = rec.username
        keyPathField.stringValue = rec.keyPath ?? ""
        tlsCheckbox.state = (rec.tls == true) ? .on : .off
        setAuth(rec.authKind ?? .password)
        let secret = rec.remembers ? ((try? store.loadSecret(for: rec)) ?? nil) ?? "" : ""
        fillSecret(secret)
    }

    /// 双击/Return：以存好的参数+密钥立即连接（成败都不写列表）。
    private func connectSelected() {
        guard let rec = selectedRecord() else { return }
        let secret = rec.remembers ? ((try? store.loadSecret(for: rec)) ?? nil) : nil
        var request = rec.request
        request.secret = secret
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
        cell?.textField?.stringValue = records[row].rowText
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

    // MARK: - 表单 → 请求（校验失败时把文案写进状态行并返回 nil）

    private func trimmed(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespaces) }

    /// 校验 + 组装当前表单。字段校验文案沿用旧两 VC（fillHost / fillServerShare /
    /// invalidPort / chooseKeyFile）。
    private func formRequest() -> RemoteConnectionRequest? {
        var req = RemoteConnectionRequest(proto: proto, name: trimmed(nameField), username: trimmed(userField))
        switch proto {
        case .sftp, .ftp:
            let host = trimmed(hostField)
            guard !host.isEmpty else {
                statusLabel.stringValue = L10n.t(.fillHost)
                return nil
            }
            guard let port = Int(trimmed(portField)), port > 0, port <= 65535 else {
                statusLabel.stringValue = L10n.t(.invalidPort)
                return nil
            }
            req.host = host
            req.port = port
            req.tls = proto == .ftp ? (tlsCheckbox.state == .on) : false
            if proto == .sftp {
                let isKey = keyRadio.state == .on
                req.authKind = isKey ? .keyFile : .password
                if isKey {
                    let kp = trimmed(keyPathField)
                    guard !kp.isEmpty else {
                        statusLabel.stringValue = L10n.t(.chooseKeyFile)
                        return nil
                    }
                    req.keyPath = kp
                    req.secret = passphraseField.stringValue.isEmpty ? nil : passphraseField.stringValue
                } else {
                    req.secret = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
                }
                return req
            }
            req.secret = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
            return req
        case .smb:
            let server = trimmed(serverField)
            let share = trimmed(shareField)
            guard !server.isEmpty, !share.isEmpty else {
                statusLabel.stringValue = L10n.t(.fillServerShare)
                return nil
            }
            req.server = server
            req.share = share
            let domain = trimmed(domainField)
            req.domain = domain.isEmpty ? nil : domain
            req.authKind = .password
            req.secret = passwordField.stringValue.isEmpty ? nil : passwordField.stringValue
            return req
        }
    }

    /// 保存用的记录（不含密钥）。id 沿用选中条目（选中保存=原位覆盖），否则新 UUID。
    private func formRecord(from req: RemoteConnectionRequest) -> RemoteConnectionRecord {
        RemoteConnectionRecord(proto: req.proto, id: selectedRecordID ?? UUID().uuidString,
                               name: req.name, host: req.host, port: req.port,
                               server: req.server, share: req.share, domain: req.domain,
                               username: req.username, authKind: req.authKind,
                               keyPath: req.keyPath, tls: req.proto == .ftp ? req.tls : nil)
    }

    // MARK: - Actions

    @objc private func protoChanged() {
        let i = protoSegment.selectedSegment
        guard i >= 0, i < RemoteProto.orderedAll.count else { return }
        setProto(RemoteProto.orderedAll[i])
    }

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
        guard let req = formRequest() else { return }
        let record = formRecord(from: req)
        do {
            _ = try store.save(record, secret: req.secret)
            statusLabel.stringValue = L10n.t(.savedDone)
        } catch RemoteConnectionStore.SaveError.listFull {
            statusLabel.stringValue = L10n.t(.savedListFull)
        } catch RemoteConnectionStore.SaveError.sameNameExists {
            let alert = NSAlert()
            alert.messageText = L10n.t(.savedDuplicateTitle)
            alert.informativeText = L10n.t(.savedDuplicateBody)
            alert.addButton(withTitle: L10n.t(.okBtn))
            alert.addButton(withTitle: L10n.t(.cancelBtn))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                _ = try store.save(record, secret: req.secret, force: true)
                statusLabel.stringValue = L10n.t(.savedDone)
            } catch RemoteConnectionStore.SaveError.listFull {
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
        guard !connecting, let req = formRequest() else { return }
        runConnect(req)
    }

    /// 连接执行公共段：token/连接中/失败态合同（供表单 Connect 与列表双击两路复用）。
    private func runConnect(_ request: RemoteConnectionRequest) {
        guard !connecting else { return }
        guard let executor = executors[request.proto] else {
            // 注入缝未接线（FTP 协议层由并行任务提供）。
            statusLabel.stringValue = L10n.t(.protoNotWired, request.proto.label)
            return
        }
        connecting = true
        connectButton.isEnabled = false
        statusLabel.stringValue = L10n.t(.connecting)
        let onConnected = self.onConnected
        let token = connectToken
        executor(request) { [weak self] result in
            guard let self, token == self.connectToken else { return }   // 表单已重置/窗口已重开
            self.connecting = false
            self.connectButton.isEnabled = true
            switch result {
            case .success(let conn):
                self.view.window?.close()
                onConnected?(conn.source, conn.home)
            case .failure(let error):
                let message = (error as? TCError).map(tcErrorDisplay) ?? error.localizedDescription
                self.statusLabel.stringValue = L10n.t(.connectFailedPrefix) + message
            }
        }
    }
}

// MARK: - 协议元数据 / 请求↔旧记录 转换（供 VC 默认执行器与接线方共用）

/// 默认执行器表（**接线适配层**，不在 VC 里）：把旧两 store 的同步 connect 包成统一
/// 合同——后台 global 队列执行、completion 回主线程（旧 VC 内联合同逐字搬移）。
/// SFTP 的 `home: String`（远端 realpath）在这里经 `SFTPSource.tcPath` 升成 TCPath。
/// **不含 ftp**：协议层由并行任务提供，接入时往表里加一项即可（缺项 → 状态行提示未接线）。
enum RemoteConnectExecutors {
    static let defaults: [RemoteProto: RemoteConnectExecutor] = [
        .sftp: { request, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<RemoteConnection, Error>
                do {
                    let (source, home) = try ConnectionStore.shared.connect(request.sftpConnectionRequest())
                    let path = SFTPSource.tcPath(host: source.config.host,
                                                 port: Int(source.config.port),
                                                 remotePath: home)
                    result = .success(RemoteConnection(source: source, home: path))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { completion(result) }
            }
        },
        .smb: { request, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<RemoteConnection, Error>
                do {
                    let (source, home) = try SMBConnectionStore.shared.connect(request.smbConnectionRequest())
                    result = .success(RemoteConnection(source: source, home: home))
                } catch { result = .failure(error) }
                DispatchQueue.main.async { completion(result) }
            }
        },
    ]
}

extension RemoteProto {
    /// 段控件顺序（三协议）。
    static let orderedAll: [RemoteProto] = [.sftp, .smb, .ftp]
    static var allLabels: [String] { orderedAll.map(\.label) }

    /// 该协议表单默认端口（sftp 22 / ftp 21 / smb 走 SMB 协议本身无端口字段）。
    var defaultPort: Int { self == .ftp ? 21 : 22 }
}

extension RemoteConnectionRequest {
    /// → 旧 SFTP 编排入口的入参（协议层合同不变，转换只在此，不在 VC）。
    func sftpConnectionRequest() -> ConnectionRequest {
        ConnectionRequest(host: host ?? "", port: UInt16(port ?? 22), username: username,
                          auth: authKind ?? .password, keyPath: keyPath, secret: secret)
    }

    /// → 旧 SMB 编排入口的入参。
    func smbConnectionRequest() -> SMBConnectionRequest {
        SMBConnectionRequest(server: server ?? "", share: share ?? "", domain: domain,
                             username: username, secret: secret)
    }
}

extension RemoteConnectionRecord {
    /// → 统一请求（列表双击直连路；secret 由调用方从 Keychain 现取覆盖）。
    var request: RemoteConnectionRequest {
        RemoteConnectionRequest(proto: proto, name: name, host: host, port: port,
                                server: server, share: share, domain: domain,
                                username: username, authKind: authKind, keyPath: keyPath,
                                secret: nil, tls: tls ?? false)
    }
}
