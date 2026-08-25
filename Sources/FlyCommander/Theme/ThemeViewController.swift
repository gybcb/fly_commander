import AppKit
import TCCore

final class ThemeViewController: NSViewController {
    private var appearanceSegment: NSSegmentedControl!
    private var accentWell: NSColorWell!
    private var rulesStack: NSStackView!

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 640))

        // 外层竖排容器
        let container = NSStackView(frame: .zero)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.distribution = .fill

        // 1) 外观
        let appearanceLabel = NSTextField(labelWithString: "外观")
        appearanceLabel.translatesAutoresizingMaskIntoConstraints = false
        let segment = NSSegmentedControl(frame: .zero)
        segment.translatesAutoresizingMaskIntoConstraints = false
        segment.segmentCount = 3
        segment.trackingMode = .selectOne
        segment.setLabel("跟随系统", forSegment: 0)
        segment.setLabel("浅色", forSegment: 1)
        segment.setLabel("深色", forSegment: 2)
        segment.target = self
        segment.action = #selector(appearanceChanged(_:))
        appearanceSegment = segment

        // 2) 强调色
        let accentLabel = NSTextField(labelWithString: "强调色（标记行底色 / 活动窗格边框）")
        accentLabel.translatesAutoresizingMaskIntoConstraints = false
        let well = NSColorWell(frame: .zero)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.isBordered = true
        well.target = self
        well.action = #selector(accentChanged(_:))
        accentWell = well

        // 3) 文件类型配色（标题 + 滚动列表 + 添加按钮）
        let rulesLabel = NSTextField(labelWithString: "文件类型配色（扩展名逗号分隔；编辑后按回车生效）")
        rulesLabel.translatesAutoresizingMaskIntoConstraints = false

        let rulesScroll = NSScrollView()
        rulesScroll.translatesAutoresizingMaskIntoConstraints = false
        rulesScroll.hasVerticalScroller = true
        rulesScroll.hasHorizontalScroller = false
        rulesScroll.autohidesScrollers = true
        let stack = NSStackView(frame: .zero)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        rulesStack = stack
        rulesScroll.documentView = stack
        // documentView 只钉 top/leading/trailing，不钉 bottom：内容超高时纵向可滚动。
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: rulesScroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: rulesScroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: rulesScroll.contentView.trailingAnchor),
        ])

        let addBtn = NSButton(title: "添加规则", target: self, action: #selector(addRule))
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        // 恢复默认
        let restoreBtn = NSButton(title: "恢复默认", target: self, action: #selector(restoreDefault))
        restoreBtn.translatesAutoresizingMaskIntoConstraints = false

        [appearanceLabel, segment, accentLabel, well, rulesLabel, rulesScroll, addBtn, restoreBtn]
            .forEach { container.addArrangedSubview($0) }
        root.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            rulesScroll.widthAnchor.constraint(equalTo: container.widthAnchor),
            rulesScroll.heightAnchor.constraint(equalToConstant: 300),
        ])

        self.view = root
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    init() { super.init(nibName: nil, bundle: nil) }

    /// 打开窗口时从 ThemeStore 读当前值刷新控件。
    func reload() {
        appearanceSegment.selectedSegment = Self.appearanceIndex(ThemeStore.shared.theme.appearance)
        accentWell.color = ThemeStore.shared.accentColor
        for sub in rulesStack.arrangedSubviews { rulesStack.removeArrangedSubview(sub); sub.removeFromSuperview() }
        for rule in ThemeStore.shared.theme.fileColorRules {
            rulesStack.addArrangedSubview(makeRuleRow(rule))
        }
    }

    // MARK: - 控件 action

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        var t = ThemeStore.shared.theme
        t.appearance = Self.appearanceFromIndex(sender.selectedSegment)
        ThemeStore.shared.update(t)
    }

    @objc private func accentChanged(_ sender: NSColorWell) {
        var t = ThemeStore.shared.theme
        t.accent = Self.colorWellToThemeColor(sender.color)
        ThemeStore.shared.update(t)
    }

    @objc private func addRule() {
        var t = ThemeStore.shared.theme
        let color = t.fileColorRules.first?.color ?? ThemeColor(red: 0, green: 0, blue: 0)
        t.fileColorRules.append(FileColorRule(extensions: ["txt"], color: color))
        ThemeStore.shared.update(t)
        reload()
    }

    @objc private func restoreDefault() {
        ThemeStore.shared.resetToDefault()
        reload()
    }

    // MARK: - 规则行 ↔ theme

    func makeRuleRow(_ rule: FileColorRule) -> FileColorRuleRowView {
        let row = FileColorRuleRowView(frame: .zero)
        row.extField.stringValue = Self.joinExtensions(rule.extensions)
        row.colorWell.color = NSColor(red: rule.color.red, green: rule.color.green,
                                      blue: rule.color.blue, alpha: rule.color.alpha)
        row.onExtensionChange = { [weak self] in self?.ruleChanged() }
        row.onColorChange = { [weak self] in self?.ruleChanged() }
        row.onDelete = { [weak self, weak row] in guard let row else { return }; self?.deleteRuleRow(row) }
        return row
    }

    private func ruleChanged() {
        var t = ThemeStore.shared.theme
        t.fileColorRules = currentRules()
        ThemeStore.shared.update(t)
    }

    private func currentRules() -> [FileColorRule] {
        rulesStack.arrangedSubviews.compactMap { $0 as? FileColorRuleRowView }.map { row in
            FileColorRule(extensions: Self.parseExtensions(row.extField.stringValue),
                          color: Self.colorWellToThemeColor(row.colorWell.color))
        }
    }

    private func deleteRuleRow(_ row: FileColorRuleRowView) {
        rulesStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        ruleChanged()
    }

    // MARK: - 纯函数（可单测）

    static func parseExtensions(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func joinExtensions(_ exts: [String]) -> String { exts.joined(separator: ", ") }

    static func appearanceIndex(_ a: Theme.Appearance) -> Int {
        switch a { case .system: return 0; case .light: return 1; case .dark: return 2 }
    }

    static func appearanceFromIndex(_ i: Int) -> Theme.Appearance {
        switch i { case 1: return .light; case 2: return .dark; default: return .system }
    }

    static func colorWellToThemeColor(_ c: NSColor) -> ThemeColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return ThemeColor(red: Double(s.redComponent), green: Double(s.greenComponent),
                          blue: Double(s.blueComponent), alpha: Double(s.alphaComponent))
    }
}

/// 一条文件类型规则行：扩展名文本框 + 取色器 + 删除按钮。
final class FileColorRuleRowView: NSView {
    let extField = NSTextField()
    let colorWell = NSColorWell(frame: .zero)
    let deleteButton = NSButton(title: "×", target: nil, action: nil)

    var onDelete: (() -> Void)?
    var onExtensionChange: (() -> Void)?
    var onColorChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        extField.translatesAutoresizingMaskIntoConstraints = false
        extField.placeholderString = "png, jpg, gif"
        extField.target = self
        extField.action = #selector(extChanged)

        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.isBordered = true
        colorWell.target = self
        colorWell.action = #selector(colorChanged)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.title = "×"
        deleteButton.bezelStyle = .roundRect
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)

        [extField, colorWell, deleteButton].forEach { addSubview($0) }
        NSLayoutConstraint.activate([
            extField.leadingAnchor.constraint(equalTo: leadingAnchor),
            extField.centerYAnchor.constraint(equalTo: centerYAnchor),
            extField.widthAnchor.constraint(equalToConstant: 210),
            colorWell.leadingAnchor.constraint(equalTo: extField.trailingAnchor, constant: 8),
            colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 40),
            deleteButton.leadingAnchor.constraint(equalTo: colorWell.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func extChanged() { onExtensionChange?() }
    @objc private func colorChanged() { onColorChange?() }
    @objc private func deleteTapped() { onDelete?() }
}
