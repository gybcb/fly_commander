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
    /// 右端常驻收藏夹按钮：点击弹出目录收藏下拉（跳转 + 收藏/取消收藏当前目录）。
    var onFavorites: (() -> Void)?
    /// 筛选行当前是否展开（开关态由 SidePaneContainer 同步）。
    var isFilterActive: Bool = false {
        didSet { filterButton.state = isFilterActive ? .on : .off }
    }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// 常驻筛选按钮：**scroll 的兄弟视图**，绝不入 stack——`rebuild` 开头清空
    /// stack.arrangedSubviews，放进去每次导航都会被销毁。
    private let filterButton = NSButton()
    /// 常驻收藏夹按钮：与 filterButton 同款兄弟视图纪律（rebuild 不销毁）。
    let favoritesButton = NSButton()

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

        // 🔽 同理（固定 24pt 宽弃文案，语义走 toolTip）。
        favoritesButton.title = "🔽"
        favoritesButton.bezelStyle = .recessed
        favoritesButton.font = .systemFont(ofSize: 11)
        favoritesButton.toolTip = L10n.t(.favoritesButtonTip)
        favoritesButton.setAccessibilityIdentifier("paneFavoritesButton")
        favoritesButton.target = self
        favoritesButton.action = #selector(favoritesClicked(_:))
        favoritesButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(favoritesButton)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: favoritesButton.leadingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            favoritesButton.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            favoritesButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoritesButton.widthAnchor.constraint(equalToConstant: 24),
            favoritesButton.heightAnchor.constraint(equalToConstant: 18),
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

    /// 三态激活视觉（用户「激活 tab 要不一样」）。旧版激活差异只有 recessed state=.on
    /// 的极浅系统底=肉眼难辨，且 isActiveSide 是死参数（另一侧 pane 的活动 tab 也画亮态）。
    /// 现由底色+字重+文字色三通道驱动，state 恒 .off（recessed pressed 自绘底会与
    /// layer 底色打架）：
    ///   当前侧活动 = accent 实底 + medium + 白字（字面 .white，见 tabVisual 内注释）
    ///   另一侧活动 = accent 25% 底 + medium（FileCellView 标记行同款）
    ///   非活动     = 无自定义底 + regular
    /// 色+字重双通道 → 不靠纯色分辨（无障碍）。纯函数出参供回归锁直测。
    struct TabVisual {
        let background: NSColor?     // nil=不覆盖系统底
        let font: NSFont
        let foreground: NSColor?     // nil=跟随系统 labelColor
    }
    static func tabVisual(isActiveTab: Bool, isActiveSide: Bool) -> TabVisual {
        guard isActiveTab else {
            return TabVisual(background: nil, font: .systemFont(ofSize: 11), foreground: nil)
        }
        return TabVisual(
            background: isActiveSide ? ThemeStore.shared.accentColor
                                     : ThemeStore.shared.accentColor.withAlphaComponent(0.25),
            font: .systemFont(ofSize: 11, weight: .medium),
            // 白字须字面值：本 SDK 下 recessed 按钮对**目录语义色**做 cell 级重映射
            // （selectedControlTextColor 实测=labelColor 别名解析为黑；alternateSelected
            // ControlTextColor 等 controlTextColor 家族在 cell 绘文本时被吞——红色/字面白
            // 像素探针背书：字面色可绘、语义色不可）。labelColor 同族也仅另一侧软底可用
            // （软底上黑/系统标签色本就是可读前景，且跟随暗色模式）。
            foreground: isActiveSide ? .white : .labelColor)
    }

    /// 重建标签。titles 顺序 = TabGroup.panes 顺序。
    func rebuild(titles: [String], activeIndex: Int, isActiveSide: Bool) {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        for (i, t) in titles.enumerated() {
            let title = NSButton(title: Self.truncate(t, max: 18),
                                 target: self, action: #selector(tabClicked(_:)))
            title.tag = i
            title.bezelStyle = .recessed
            let visual = Self.tabVisual(isActiveTab: i == activeIndex, isActiveSide: isActiveSide)
            if let bg = visual.background {
                title.wantsLayer = true
                title.layer?.backgroundColor = bg.cgColor
                let ps = NSMutableParagraphStyle()
                ps.alignment = .center
                var attrs: [NSAttributedString.Key: Any] = [.font: visual.font, .paragraphStyle: ps]
                if let fg = visual.foreground { attrs[.foregroundColor] = fg }
                title.attributedTitle = NSAttributedString(string: title.title, attributes: attrs)
            } else {
                title.font = visual.font
            }
            title.state = .off
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

        // 常驻筛选/收藏按钮不在 stack 里，rebuild 不重建它们——但 toolTip 在此重刷，
        // 语言切换走的正是 rebuild 这条路。
        filterButton.toolTip = L10n.t(.filterButtonTip)
        favoritesButton.toolTip = L10n.t(.favoritesButtonTip)
    }

    @objc private func tabClicked(_ sender: NSButton) { onSwitchTab?(sender.tag) }
    @objc private func closeClicked(_ sender: NSButton) { onCloseTab?(sender.tag) }
    @objc private func plusClicked(_ sender: NSButton) { onNewTab?() }
    @objc private func filterClicked(_ sender: NSButton) { onToggleFilter?() }
    @objc private func favoritesClicked(_ sender: NSButton) { onFavorites?() }

    /// 纯函数：字符级截断（>max 保留前 max-1 字符 + "…"）。供单测。
    static func truncate(_ s: String, max: Int) -> String {
        guard s.count > max, max >= 2 else { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    #if DEBUG
    /// 测试钩子：按 tag 升序回读各标签标题按钮（激活态视觉回归锁读 layer 底色/attributedTitle）。
    /// 判据=action 精确等于 tabClicked（标题/关闭按钮 tag 同为 i，按 tag 或标题串筛都会误伤）；
    /// 只读不改状态，生产路径零调用。
    func titleButtonsForTest() -> [NSButton] {
        stack.arrangedSubviews.compactMap { $0 as? NSButton }
            .filter { $0.action == #selector(tabClicked(_:)) }
            .sorted { $0.tag < $1.tag }
    }
    #endif
}
