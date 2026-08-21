import Foundation

public struct SelectionModel: Equatable {
    public enum MoveMode: Equatable { case simple, additive, range }

    private(set) public var items: [String] = []
    private(set) public var focusIndex: Int = 0
    private(set) public var marked: Set<String> = []
    private var anchor: Int?

    public init() {}

    public mutating func reload(with ids: [String]) {
        items = ids
        focusIndex = 0
        marked = []
        anchor = nil
    }

    public var hasItems: Bool { !items.isEmpty }
    public var focusID: String? { items.indices.contains(focusIndex) ? items[focusIndex] : nil }

    public func isMarked(_ id: String) -> Bool { marked.contains(id) }
    public func isFocus(_ id: String) -> Bool { id == focusID }

    public var markedIDs: [String] { items.filter { marked.contains($0) } }
    public var operationIDs: [String] { markedIDs.isEmpty ? (focusID.map { [$0] } ?? []) : markedIDs }

    public mutating func moveFocus(to target: Int, mode: MoveMode) {
        guard hasItems else { return }
        let clamped = min(max(target, 0), items.count - 1)
        let oldFocus = focusIndex
        switch mode {
        case .simple:
            focusIndex = clamped
            marked = []
            anchor = nil
        case .additive:
            marked.insert(items[clamped])
            focusIndex = clamped
        case .range:
            if anchor == nil { anchor = oldFocus }
            let a = anchor!
            for i in min(a, clamped)...max(a, clamped) { marked.insert(items[i]) }
            focusIndex = clamped
        }
    }

    public mutating func moveFocusBy(delta: Int, mode: MoveMode) {
        moveFocus(to: focusIndex + delta, mode: mode)
    }

    public mutating func setFocus(to index: Int) {
        guard hasItems else { return }
        focusIndex = min(max(index, 0), items.count - 1)
    }

    public mutating func toggleMark() {
        guard let id = focusID else { return }
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
    }

    public mutating func toggleMark(at index: Int) {
        guard items.indices.contains(index) else { return }
        let id = items[index]
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
    }

    public mutating func selectAll() { marked = Set(items) }
    public mutating func clearMarks() { marked = []; anchor = nil }
}
