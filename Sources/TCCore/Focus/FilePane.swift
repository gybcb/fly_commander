import Foundation

public enum PaneID: Equatable { case left, right }

public final class FilePane {
    public let id: PaneID
    private let source: FileSource
    public private(set) var path: TCPath
    public private(set) var selection = SelectionModel()
    public private(set) var page: DirectoryPage?

    public var onReload: ((FilePane) -> Void)?

    public init(id: PaneID, source: FileSource, startPath: TCPath) {
        self.id = id
        self.source = source
        self.path = startPath
    }

    public var itemByID: [String: FileItem] {
        guard let page else { return [:] }
        return Dictionary(uniqueKeysWithValues: page.items.map { ($0.id, $0) })
    }

    public var operationTargets: [FileItem] {
        let byID = itemByID
        return selection.operationIDs.compactMap { byID[$0] }
    }

    public var focusedItem: FileItem? { selection.focusID.flatMap { itemByID[$0] } }
    public var itemCount: Int { page?.items.count ?? 0 }

    public func load(preserveFocus: Bool = true) {
        let keep = preserveFocus ? selection.focusID : nil
        do {
            let items = try source.listDirectory(path)
            let page = DirectoryPage(path: path, items: items)
            self.page = page
            selection.reload(with: items.map { $0.id }, previousFocusID: keep)
        } catch {
            self.page = DirectoryPage(path: path, items: [])
            selection.reload(with: [])
        }
        onReload?(self)
    }

    public func navigate(to newPath: TCPath) {
        guard newPath.isRoot || source.isDirectory(newPath) else { return }
        path = newPath
        load(preserveFocus: false)
    }

    public func enterFocusedDirectory() {
        if let item = focusedItem, item.isDirectory { navigate(to: item.path) }
    }

    public func gotoParent() {
        if let p = path.parent { navigate(to: p) }
    }

    public func moveFocus(to index: Int, mode: SelectionModel.MoveMode) {
        selection.moveFocus(to: index, mode: mode)
        onReload?(self)
    }
    public func moveFocusBy(delta: Int, mode: SelectionModel.MoveMode) {
        selection.moveFocusBy(delta: delta, mode: mode)
        onReload?(self)
    }
    public func setFocus(to index: Int) { selection.setFocus(to: index); onReload?(self) }
    public func toggleMark() { selection.toggleMark(); onReload?(self) }
    public func toggleMark(at index: Int) { selection.toggleMark(at: index); onReload?(self) }
    public func selectAll() { selection.selectAll(); onReload?(self) }
    public func clearMarks() { selection.clearMarks(); onReload?(self) }
}
