import Foundation
import TCCore

/// 应用语言。rawValue 存入 UserDefaults["appLanguage"]。
enum Language: String { case en, zh }

/// 本地化门面（AppKit 层）。内核零文案，仅 key 与表；t() 在此查表并做 {n} 插值。
enum L10n {
    private static let key = "appLanguage"
    private static var nextToken = 0
    private static var tokens: [Int: () -> Void] = [:]   // 用 id 支持 unobserve

    /// 当前语言。set 写入 UserDefaults 并向所有观察者广播。
    static var current: Language {
        get { currentResolved }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            _current = newValue
            for cb in tokens.values { cb() }
        }
    }
    private static var _current: Language?
    private static var currentResolved: Language {
        if let c = _current { return c }
        if let raw = UserDefaults.standard.string(forKey: key), let l = Language(rawValue: raw) { return l }
        return .en   // 默认英文
    }
    #if DEBUG
    static var currentResolvedForTest: Language { currentResolved }
    #endif

    /// 查表 + 位置插值（{0}、{1}…）。zh 缺 key 落 en，仍缺落 rawValue。
    static func t(_ k: L10nKey, _ args: String...) -> String {
        t(k, args: args)
    }
    /// 数组重载：供 TCError.l10nArgs 等结构化参数直接传入（variadic 版委托它）。
    /// 单趟扫描替换：只替换**模板**里的 `{i}`，arg 的**内容**（Plan B 可能是远端文件名/
    /// Traversio message，含 `{1}` 字面量）不参与二次扫描——防逐 arg 顺序替换的污染。
    static func t(_ k: L10nKey, args: [String]) -> String {
        let table = current == .en ? L10nTable.en : L10nTable.zh
        let tmpl = table[k] ?? L10nTable.en[k] ?? k.rawValue
        guard !args.isEmpty else { return tmpl }
        var out = ""
        var i = tmpl.startIndex
        while i < tmpl.endIndex {
            if tmpl[i] == "{",
               let close = tmpl[i...].firstIndex(of: "}"),
               let idx = Int(tmpl[tmpl.index(after: i)..<close]),
               idx >= 0, idx < args.count {
                out += args[idx]
                i = tmpl.index(after: close)
            } else {
                out.append(tmpl[i])
                i = tmpl.index(after: i)
            }
        }
        return out
    }
    /// 注册切换回调，返回 token 供 unobserve。
    static func observe(_ cb: @escaping () -> Void) -> Int {
        let id = nextToken; nextToken += 1; tokens[id] = cb; return id
    }
    /// 按 token 注销。
    static func unobserve(_ id: Int) {
        tokens.removeValue(forKey: id)
    }
}
