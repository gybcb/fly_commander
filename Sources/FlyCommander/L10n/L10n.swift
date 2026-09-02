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
        let table = current == .en ? L10nTable.en : L10nTable.zh
        var s = table[k] ?? L10nTable.en[k] ?? k.rawValue
        for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: a) }
        return s
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
