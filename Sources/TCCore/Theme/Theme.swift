import Foundation

/// 中性颜色（RGBA，TCCore 零 AppKit，不依赖 NSColor）。
public struct ThemeColor: Codable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

/// 一条"扩展名集合 → 颜色"的文件上色规则。
public struct FileColorRule: Codable, Equatable {
    public var extensions: [String]   // 小写、不含点（如 ["png","jpg"]）
    public var color: ThemeColor

    public init(extensions: [String], color: ThemeColor) {
        self.extensions = extensions
        self.color = color
    }
}

public struct Theme: Codable, Equatable {
    public enum Appearance: String, Codable, CaseIterable { case system, light, dark }

    public var appearance: Appearance
    public var accent: ThemeColor
    public var fileColorRules: [FileColorRule]

    public init(appearance: Appearance, accent: ThemeColor, fileColorRules: [FileColorRule]) {
        self.appearance = appearance
        self.accent = accent
        self.fileColorRules = fileColorRules
    }

    /// 出厂主题：跟随系统 + 系统蓝强调色 + 预置文件类型规则。
    public static let `default` = Theme(
        appearance: .system,
        accent: ThemeColor(red: 0.0, green: 0.478, blue: 1.0),
        fileColorRules: [
            FileColorRule(extensions: ["txt","md","log","swift","py","js","ts","json","xml","yml","yaml","sh","c","h","html","css","sql"],
                          color: ThemeColor(red: 0.25, green: 0.4, blue: 0.6)),
            FileColorRule(extensions: ["png","jpg","jpeg","gif","heic","webp","svg","bmp","tiff"],
                          color: ThemeColor(red: 0.1, green: 0.6, blue: 0.2)),
            FileColorRule(extensions: ["mp4","mov","mkv","avi","webm"],
                          color: ThemeColor(red: 0.5, green: 0.3, blue: 0.7)),
            FileColorRule(extensions: ["mp3","wav","flac","m4a","aac","ogg"],
                          color: ThemeColor(red: 0.9, green: 0.5, blue: 0.1)),
            FileColorRule(extensions: ["zip","tar","gz","bz2","7z","rar"],
                          color: ThemeColor(red: 0.6, green: 0.4, blue: 0.2)),
        ]
    )
}

/// 提取文件扩展名（小写、不含点）；无扩展名 / 纯点 / 尾点返回 nil。
public func fileExtension(_ name: String) -> String? {
    guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return nil }
    let ext = name[name.index(after: dot)...].lowercased()
    return ext.isEmpty ? nil : ext
}

/// 命中首条扩展名规则即返回；目录 / 无扩展名返回 nil。
public func matchFileColorRule(_ item: FileItem, rules: [FileColorRule]) -> FileColorRule? {
    guard !item.isDirectory else { return nil }
    guard let ext = fileExtension(item.name) else { return nil }
    return rules.first { $0.extensions.contains(ext) }
}
