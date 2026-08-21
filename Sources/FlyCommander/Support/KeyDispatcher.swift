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
            return DispatchResult(command: .up, moveMode: .simple)
        case 125: // Down
            if has(.control) { return DispatchResult(command: .down, moveMode: .additive) }
            if has(.shift) { return DispatchResult(command: .down, moveMode: .range) }
            return DispatchResult(command: .down, moveMode: .simple)
        case 123: // Left
            return has(.control) ? DispatchResult(command: .switchPane, moveMode: .simple)
                                 : DispatchResult(command: .parent, moveMode: .simple)
        case 124: // Right
            return has(.control) ? DispatchResult(command: .switchPane, moveMode: .simple)
                                 : DispatchResult(command: .enter, moveMode: .simple)
        case 116: return DispatchResult(command: .pageUp, moveMode: .simple)
        case 121: return DispatchResult(command: .pageDown, moveMode: .simple)
        case 115: return DispatchResult(command: .home, moveMode: .simple)
        case 119: return DispatchResult(command: .end, moveMode: .simple)
        case 36, 76: return DispatchResult(command: .enter, moveMode: .simple) // Return / numpad Enter
        case 48: return DispatchResult(command: .switchPane, moveMode: .simple) // Tab
        case 51: return DispatchResult(command: .parent, moveMode: .simple)    // Backspace/Delete
        case 117: return DispatchResult(command: .rename, moveMode: .simple)   // Fn+Delete
        case 49: return DispatchResult(command: .toggleMark, moveMode: .simple) // Space
        case 53: return DispatchResult(command: .clearMarks, moveMode: .simple) // Esc
        case 96: return DispatchResult(command: .copy, moveMode: .simple)       // F5
        case 97: return DispatchResult(command: .move, moveMode: .simple)       // F6
        case 98: return DispatchResult(command: .makeDirectory, moveMode: .simple) // F7
        case 99: return DispatchResult(command: .delete, moveMode: .simple)     // F8
        case 12: // Q
            return has(.option) ? DispatchResult(command: .toggleMark, moveMode: .simple) : nil
        case 0: // A
            return has(.command) ? DispatchResult(command: .selectAll, moveMode: .simple) : nil
        default: return nil
        }
    }
}
