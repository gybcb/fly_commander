import AppKit
import TCCore

/// 设计令牌（视觉 polish 一期的唯一落点）：语义色 + 字号 + 度量集中一处。
/// 规则：视图不得再新增裸 NSColor 字面量/字号魔数——从这里取。
/// 色一律给**动态 NSColor**（cgColor 解算仍由各视图在
/// effectiveAppearance.performAsCurrentDrawingAppearance 内做——缩减 SDK 定格坑，
/// 见 AppearanceRefreshTests）；本文件只做合成，不碰 layer。
enum Style {
    // MARK: - 语义色（全部由动态系统色合成 → 明暗自随动）

    /// 焦点行·活动窗格：accent 实底（名称反白）。
    static var rowFocused: NSColor { ThemeStore.shared.accentColor }
    /// 焦点行·活动窗格的前景色。
    static var rowFocusedText: NSColor { .white }
    /// 焦点行·非活动窗格：系统非强调选中底（Finder 惯例灰调；unifiedTitleBarTextColor
    /// 在本缩减 SDK 不存在——探针实证，2026-09-28）。
    static var rowFocusedInactive: NSColor { .unemphasizedSelectedContentBackgroundColor }
    /// 焦点行·非活动的名称色（灰底上的可读正文，不反白）。
    static var rowFocusedInactiveText: NSColor { .labelColor }
    /// 标记行：accent 淡底（18%，比旧 25% 轻一档，和焦点实底拉开层级）。
    static var rowMarked: NSColor { ThemeStore.shared.accentColor.withAlphaComponent(0.18) }
    /// 普通行底。
    static var rowPlain: NSColor { .controlBackgroundColor }
    /// 斑马纹（偶数行微染）：secondaryLabel 3% ——明暗两态都是"几乎看不出但有锚"。
    static var rowZebra: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.03) }

    /// tab 胶囊底（当前侧活动=accent 15% 胶囊；另一侧活动沿用 25% 见 TabBarView）。
    static var tabActivePill: NSColor { ThemeStore.shared.accentColor.withAlphaComponent(0.15) }

    // MARK: - 字号（type scale：正文 13 / 元数据 11 / 数字 11 等宽数字）

    /// 行名称。
    static let cellNameFont = NSFont.systemFont(ofSize: 12)
    static let cellNameFontFocused = NSFont.systemFont(ofSize: 12, weight: .medium)
    /// size/date 元数据：等宽数字（列内数字位对齐，不随内容跳动）。
    static let cellMetaFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    // MARK: - 度量

    /// 文件行高（20→22：16pt 图标上下各留 3pt 呼吸）。
    static let rowHeight: CGFloat = 22
}
