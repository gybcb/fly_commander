import Foundation
import AppKit
import TCCore

struct KeyInput {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

struct DispatchResult {
    let command: CommandID
    let moveMode: SelectionModel.MoveMode
}

enum KeyDispatcher {
    static func dispatch(_ input: KeyInput) -> DispatchResult? {
        let m = input.modifiers.intersection([.command, .control, .option, .shift])
        func has(_ flags: NSEvent.ModifierFlags) -> Bool { m.contains(flags) }

        switch input.keyCode {
        case 126: // Up
            if has(.control) { return DispatchResult(command: .up, moveMode: .additive) }
            if has(.shift) { return DispatchResult(command: .up, moveMode: .range) }
            // TC 粘性标记：plain 方向键移焦点但标记集不变（core .sticky）
            return DispatchResult(command: .up, moveMode: .sticky)
        case 125: // Down
            if has(.control) { return DispatchResult(command: .down, moveMode: .additive) }
            if has(.shift) { return DispatchResult(command: .down, moveMode: .range) }
            return DispatchResult(command: .down, moveMode: .sticky)
        case 123: // Left
            return has(.control) ? DispatchResult(command: .switchPane, moveMode: .simple)
                                 : DispatchResult(command: .parent, moveMode: .simple)
        case 124: // Right：无修饰=激活命令栏（TC 行为）；Ctrl=切窗格
            return has(.control) ? DispatchResult(command: .switchPane, moveMode: .simple)
                                 : DispatchResult(command: .activateCommandLine, moveMode: .simple)
        case 116: return DispatchResult(command: .pageUp, moveMode: .sticky)
        case 121: return DispatchResult(command: .pageDown, moveMode: .sticky)
        case 115: return DispatchResult(command: .home, moveMode: .sticky)
        case 119: return DispatchResult(command: .end, moveMode: .sticky)
        case 36, 76: return DispatchResult(command: .enter, moveMode: .simple) // Return / numpad Enter
        case 48: // Tab：无修饰=切左右窗格（TC 原行为）；Ctrl=切本侧标签
            if has(.control) {
                return has(.shift) ? DispatchResult(command: .prevTab, moveMode: .simple)
                                   : DispatchResult(command: .nextTab, moveMode: .simple)
            }
            return DispatchResult(command: .switchPane, moveMode: .simple)
        case 51: return DispatchResult(command: .parent, moveMode: .simple)    // Backspace/Delete
        case 117: return DispatchResult(command: .rename, moveMode: .simple)   // Fn+Delete
        case 49: return DispatchResult(command: .toggleMark, moveMode: .simple) // Space
        case 53: return DispatchResult(command: .clearMarks, moveMode: .simple) // Esc
        case 96: return DispatchResult(command: .copy, moveMode: .simple)        // F5 (kVK_F5=0x60)
        case 97: return DispatchResult(command: .move, moveMode: .simple)        // F6 (kVK_F6=0x61)
        case 98: return DispatchResult(command: .makeDirectory, moveMode: .simple) // F7 (kVK_F7=0x62)
        case 99: return DispatchResult(command: .viewFile, moveMode: .simple)    // F3 (kVK_F3=0x63)
        case 100: return DispatchResult(command: .delete, moveMode: .simple)     // F8 (kVK_F8=0x64)
        case 118: return DispatchResult(command: .editFile, moveMode: .simple)   // F4 (kVK_F4=0x76)
        case 12: // Q
            return has(.option) ? DispatchResult(command: .toggleMark, moveMode: .simple) : nil
        default: return nil
        }
    }
}
