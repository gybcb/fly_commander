import Foundation

public enum PaneID: Equatable { case left, right }

public final class FilePane {
    public let id: PaneID
    public private(set) var source: FileSource
    public private(set) var path: TCPath
    public private(set) var selection = SelectionModel()
    public private(set) var page: DirectoryPage?
    /// 最近一次加载的错误（本地源一般恒 nil；远端断连/权限错误在此暴露）。
    public private(set) var lastError: TCError?

    public var onReload: ((FilePane) -> Void)?

    private var loadToken = 0
    private let loadQueue = DispatchQueue(label: "fly.filepane.load")

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

    /// Focus the item with this id if it is on the current page (used after
    /// jumping to a directory from search results).
    @discardableResult
    public func revealItem(id: String) -> Bool {
        guard let idx = selection.items.firstIndex(of: id) else { return false }
        selection.setFocus(to: idx)
        onReload?(self)
        return true
    }

    public func load(preserveFocus: Bool = true) {
        let keep = preserveFocus ? selection.focusID : nil
        do {
            let items = try source.listDirectory(path)
            self.page = DirectoryPage(path: path, items: items)
            selection.reload(with: items.map { $0.id }, previousFocusID: keep)
            lastError = nil
        } catch let tc as TCError {
            self.page = DirectoryPage(path: path, items: [])
            selection.reload(with: [])
            lastError = tc
        } catch {
            self.page = DirectoryPage(path: path, items: [])
            selection.reload(with: [])
            lastError = TCError.unknown(error.localizedDescription)
        }
        onReload?(self)
    }

    /// 后台加载（远端源专用）：listDirectory 在专用队列执行，
    /// 结果回主线程更新 page/selection/onReload；token 防旧结果覆盖新导航。
    public func loadAsync(preserveFocus: Bool = true) {
        let keep = preserveFocus ? selection.focusID : nil
        let token = { loadToken &+= 1; return loadToken }()
        let capturedPath = path
        loadQueue.async { [source] in
            let result: Result<[FileItem], Error>
            do { result = .success(try source.listDirectory(capturedPath)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }   // 已有更新的加载
                switch result {
                case .success(let items):
                    self.page = DirectoryPage(path: capturedPath, items: items)
                    self.selection.reload(with: items.map { $0.id }, previousFocusID: keep)
                    self.lastError = nil
                case .failure(let error):
                    self.page = DirectoryPage(path: capturedPath, items: [])
                    self.selection.reload(with: [])
                    self.lastError = error as? TCError
                        ?? TCError.unknown(error.localizedDescription)
                }
                self.onReload?(self)
            }
        }
    }

    /// 切换数据源（SFTP 连接成功后把窗格接到远端）。
    public func setSource(_ newSource: FileSource, andPath newPath: TCPath) {
        loadToken &+= 1   // 使在途的旧源加载失效
        source = newSource
        path = newPath
        selection = SelectionModel()
        page = nil
        lastError = nil
        if newSource.isRemote {
            loadAsync(preserveFocus: false)
        } else {
            load(preserveFocus: false)
        }
    }

    public func navigate(to newPath: TCPath) {
        guard newPath.isRoot || (try? source.stat(newPath))?.isDirectory == true else { return }
        path = newPath
        if source.isRemote {
            loadAsync(preserveFocus: false)
        } else {
            load(preserveFocus: false)
        }
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
