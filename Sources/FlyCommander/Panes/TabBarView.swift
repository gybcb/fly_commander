import AppKit
import TCCore

/// TC 式标签条：每个标签一个标题按钮 + 一个"×"关闭按钮，末尾固定"+"新建按钮。
/// 纯 AppKit 视图；可单测点=纯函数 truncate。所有子视图 translates=false（reduced-SDK）。
final class TabBarView: NSView {
    static let barHeight: CGFloat = 28

    var onSwitchTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: ((Int) -> Void)?
    /// 右端常驻筛选按钮：点击展开/收起活动窗格的筛选行。
    var onToggleFilter: (() -> Void)?
    /// 筛选行当前是否展开（开关态由 SidePaneContainer 同步）。
    var isFilterActive: Bool = false {
        didSet { filterButton.state = isFilterActive ? .on : .off }
    }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// 常驻筛选按钮：**scroll 的兄弟视图**，绝不入 stack——`rebuild` 开头清空
    /// stack.arrangedSubviews，放进去每次导航都会被销毁。
    private let filterButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        addSubview(scroll)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        scroll.documentView = stack

        // 标题用 🔍 而非文案：固定 24pt 宽放不下中英文长词，且与 ⌘⇧F 菜单项标题
        // （L10n.t(.filterButtonTip)）同串会污染 AX 定位；语义走 toolTip。
        filterButton.title = "🔍"
        filterButton.bezelStyle = .recessed
        filterButton.font = .systemFont(ofSize: 11)
        filterButton.toolTip = L10n.t(.filterButtonTip)
        filterButton.setAccessibilityIdentifier("paneFilterButton")
        filterButton.target = self
        filterButton.action = #selector(filterClicked(_:))
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            filterButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            filterButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 24),
            filterButton.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 重建标签。titles 顺序 = TabGroup.panes 顺序。
    func rebuild(titles: [String], activeIndex: Int, isActiveSide: Bool) {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        for (i, t) in titles.enumerated() {
            let title = NSButton(title: Self.truncate(t, max: 18),
                                 target: self, action: #selector(tabClicked(_:)))
            title.tag = i
            title.bezelStyle = .recessed
            title.font = .systemFont(ofSize: 11)
            title.state = (i == activeIndex) ? .on : .off
            title.toolTip = t
            stack.addArrangedSubview(title)

            let close = NSButton(title: "×", target: self, action: #selector(closeClicked(_:)))
            close.tag = i
            close.isBordered = false              // Chrome 式：无边框紧凑小 ×（弃 .recessed 圆角盒，省空间）
            close.font = .systemFont(ofSize: 10, weight: .medium)
            close.toolTip = L10n.t(.closeTabTip)
            close.isHidden = titles.count <= 1   // 唯一标签不显示 ×（保底 1）
            close.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(close)
            NSLayoutConstraint.activate([
                close.widthAnchor.constraint(equalToConstant: 16),
                close.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
        let plus = NSButton(title: "+", target: self, action: #selector(plusClicked(_:)))
        plus.bezelStyle = .recessed
        plus.font = .systemFont(ofSize: 11, weight: .bold)
        plus.toolTip = L10n.t(.newTabTip)
        stack.addArrangedSubview(plus)

        // 常驻筛选按钮不在 stack 里，rebuild 不重建它——但 toolTip 在此重刷，
        // 语言切换走的正是 rebuild 这条路。
        filterButton.toolTip = L10n.t(.filterButtonTip)
    }

    @objc private func tabClicked(_ sender: NSButton) { onSwitchTab?(sender.tag) }
    @objc private func closeClicked(_ sender: NSButton) { onCloseTab?(sender.tag) }
    @objc private func plusClicked(_ sender: NSButton) { onNewTab?() }
    @objc private func filterClicked(_ sender: NSButton) { onToggleFilter?() }

    /// 纯函数：字符级截断（>max 保留前 max-1 字符 + "…"）。供单测。
    static func truncate(_ s: String, max: Int) -> String {
        guard s.count > max, max >= 2 else { return s }
        return String(s.prefix(max - 1)) + "…"
    }
}
