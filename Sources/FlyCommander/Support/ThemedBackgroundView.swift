import AppKit

/// 底色随外观自动重解的容器视图：存**动态 NSColor 本体**（不是解算后的 CGColor），
/// 底色写进 `updateLayer()`——AppKit 在 effectiveAppearance 变化时自动重跑该方法，
/// 系统切明暗即翻色。给预览窗各内容容器用（旧写法 init 里 `.cgColor` 定格旧外观）。
final class ThemedBackgroundView: NSView {
    var backgroundColor: NSColor = .controlBackgroundColor {
        didSet { applyBackgroundColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyBackgroundColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    convenience init(color: NSColor) {
        self.init(frame: .zero)
        backgroundColor = color
    }

    private func applyBackgroundColor() {
        layer?.backgroundColor = backgroundColor.cgColor
    }

    /// 与全仓同款显式钩子（updateLayer 自动路径在测试环境实测不跑，不赌时机）。
    /// backgroundColor 存动态 NSColor 本体 → 钩子里重解即随明暗翻。解算钉进
    /// performAsCurrentDrawingAppearance：钩子瞬间 currentDrawing 可能仍是旧外观
    /// （真机实证，见 FileCellView 同款注释）。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applyBackgroundColor()
        }
    }
}
