import AppKit
import TCCore

enum PaneColor {
    static let navy = NSColor(red: 0.0, green: 0.0, blue: 80.0 / 255.0, alpha: 1.0)
    static let markedBlue = NSColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)

    static func background(for role: FileVisualRole, active: Bool, dark: Bool) -> NSColor {
        role == .focus ? navy : .clear
    }

    static func text(for role: FileVisualRole, dark: Bool) -> NSColor {
        switch role {
        case .focus: return .white
        case .marked: return markedBlue
        case .hidden, .readOnly: return .gray
        case .directory, .normal: return dark ? .white : .black
        }
    }

    static func isBold(_ role: FileVisualRole) -> Bool {
        role == .directory || role == .focus
    }
}
