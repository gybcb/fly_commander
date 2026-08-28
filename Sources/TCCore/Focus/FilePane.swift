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
        // uniquingKeysWith：远端列表由服务器返回，重复 id 不得 trap（保留首条）。
        return Dictionary(page.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    public func load(preserveFocus: Bool = true, focusID: String? = nil) {
        do {
            let items = try source.listDirectory(path)
            let ids = items.map { $0.id }
            self.page = DirectoryPage(path: path, items: items)
            if let target = focusID {
                // 跨目录导航（回退/搜索）：清空标记，再按 id/name 定位到目标项。
                selection.reload(with: ids)
                applyExplicitFocus(target, items: items)
            } else {
                // 原地刷新（如 F5/F6 后）：reload(previousFocusID:) 保留焦点与标记集。
                selection.reload(with: ids,
                                 previousFocusID: preserveFocus ? selection.focusID : nil)
            }
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

    /// 跨目录导航后的显式定位：按 id、再按 name（lastPathComponent）兜底——同目录
    /// 名字唯一，本地/远端皆成立。找不到时落回首项。此时标记集已随 reload 清空。
    private func applyExplicitFocus(_ target: String, items: [FileItem]) {
        guard !items.isEmpty else { return }
        if let idx = items.firstIndex(where: { $0.id == target
                    || $0.name == (target as NSString).lastPathComponent }) {
            selection.setFocus(to: idx)
        } else {
            selection.setFocus(to: 0)
        }
    }

    /// 后台加载（远端源专用）：listDirectory 在专用队列执行，
    /// 结果回主线程更新 page/selection/onReload；token 防旧结果覆盖新导航。
    public func loadAsync(preserveFocus: Bool = true, focusID: String? = nil) {
        let previousFocusID = selection.focusID
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
                    let ids = items.map { $0.id }
                    self.page = DirectoryPage(path: capturedPath, items: items)
                    if let target = focusID {
                        // 跨目录导航（回退/搜索）：清空标记，再按 id/name 定位到目标项。
                        self.selection.reload(with: ids)
                        self.applyExplicitFocus(target, items: items)
                    } else {
                        // 原地刷新：reload(previousFocusID:) 保留焦点与标记集。
                        self.selection.reload(with: ids,
                                              previousFocusID: preserveFocus ? previousFocusID : nil)
                    }
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

    public func navigate(to newPath: TCPath, focusID: String? = nil) {
        guard newPath.isRoot || (try? source.stat(newPath))?.isDirectory == true else { return }
        path = newPath
        if source.isRemote {
            loadAsync(preserveFocus: false, focusID: focusID)
        } else {
            load(preserveFocus: false, focusID: focusID)
        }
    }

    public func enterFocusedDirectory() {
        if let item = focusedItem, item.isDirectory { navigate(to: item.path) }
    }

    /// 回退到父目录并**定位到刚离开的子目录**（TC 行为）。当前 path 即父列表里那个
    /// 子目录，其 id 恰为 path.pathString（本地 FileItem.id == url.path == pathString；
    /// 远端同理，id 来自路径）。focusID 不存在时 navigate 落回首项。
    public func gotoParent() {
        let leftID = path.pathString
        if let p = path.parent { navigate(to: p, focusID: leftID) }
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
