import AppKit
import TCCore

enum PaneColor {
    static let navy = NSColor(red: 0.0, green: 0.0, blue: 80.0 / 255.0, alpha: 1.0)
    static let markedBlue = NSColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)

    static func background(for role: FileVisualRole, active: Bool, dark: Bool) -> NSColor {
        switch role {
        case .focus: return navy
        case .marked: return markedBlue
        default: return .clear
        }
    }

    static func text(for role: FileVisualRole, dark: Bool) -> NSColor {
        switch role {
        case .focus, .marked: return .white
        case .hidden, .readOnly: return .secondaryLabelColor
        case .directory, .normal: return .labelColor
        }
    }

    static func border(for role: FileVisualRole) -> NSColor? {
        role == .focus ? .white : nil
    }

    static func isBold(_ role: FileVisualRole) -> Bool {
        role == .directory || role == .focus
    }
}
