import Foundation
import AppKit
import TCCore

/// 主题门面：持久化（UserDefaults+JSON，键 "theme"）+ 外观应用 + NSColor 解析。
/// 仿 ConnectionStore：单例 + 可注入 UserDefaults（单测用独立 suite，不碰 .standard）。
final class ThemeStore {
    static let shared = ThemeStore()

    private let defaults: UserDefaults
    private let storeKey = "theme"
    private(set) var theme: Theme

    /// 主题变化通知（MainViewController 订阅后刷新两窗格）。
    var didChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let t = try? JSONDecoder().decode(Theme.self, from: data) {
            self.theme = t
        } else {
            self.theme = .default
        }
        applyAppearance()
    }

    var accentColor: NSColor {
        NSColor(red: theme.accent.red, green: theme.accent.green,
                blue: theme.accent.blue, alpha: theme.accent.alpha)
    }

    /// 文件名文本色：命中规则→规则色；否则 labelColor（目录恒 labelColor）。
    func nameColor(for item: FileItem) -> NSColor {
        if let rule = matchFileColorRule(item, rules: theme.fileColorRules) {
            return NSColor(red: rule.color.red, green: rule.color.green,
                           blue: rule.color.blue, alpha: rule.color.alpha)
        }
        return .labelColor
    }

    func update(_ newTheme: Theme) {
        theme = newTheme
        persist()
        applyAppearance()
        didChange?()
    }

    func resetToDefault() { update(.default) }

    private func persist() {
        guard let data = try? JSONEncoder().encode(theme) else { return }
        defaults.set(data, forKey: storeKey)
    }

    /// 应用外观到整个 app（惰性 no-op，无 GUI 进程下安全）。
    func applyAppearance() {
        let app = NSApplication.shared
        switch theme.appearance {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
