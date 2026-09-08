import Foundation

public enum PaneID: Equatable { case left, right }

public final class FilePane {
    public let id: PaneID
    public private(set) var source: FileSource
    public private(set) var path: TCPath
    public private(set) var selection = SelectionModel()
    /// 可见集的**单一失效点**：`page` 的每次赋值（load/loadAsync 的成功与失败、setSource）
    /// 都经 `didSet` 重算缓存，结构上不可能陈旧。
    public private(set) var page: DirectoryPage? {
        didSet { recomputeVisibility() }
    }
    /// 最近一次加载的错误（本地源一般恒 nil；远端断连/权限错误在此暴露）。
    public private(set) var lastError: TCError?

    // MARK: - 筛选状态（决策 3：仅当前目录生效，导航清空、刷新保留）

    /// 当前筛选文本（空 = 无筛选）。视图筛选行每键击经 `setFilter` 写入。
    public private(set) var filterText = ""
    private var filter: NameFilter?
    /// 可见项 id，**存储序**（= `page.items` 顺序）；nil = 无筛选。
    private var visibleIDs: [String]?
    /// 可见性门禁用集合；nil = 无筛选（门禁默认放行）。
    private var visibleIDSet: Set<String>?

    public var onReload: ((FilePane) -> Void)?
    /// 选择态变化快路（方向键/空格/单击焦点）：内容（page/selection.items）未变、
    /// 只有 focus/marks 变时触发。消费方走局部刷新即可——onReload 的全量路要重排
    /// sortedIDs（大目录实测 37ms/键）+ 重建标签条，是"方向键慢半拍"的根因。
    /// before/after diff 无实际变化（末行再下移等）→ 一个回调都不发，零渲染。
    public var onSelectionChange: ((FilePane) -> Void)?

    private var loadToken = 0
    /// 远端 navigate 的在途 stat 校验（新导航/setSource 使旧 hop 失效）。
    private var navToken = 0
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
        return selection.operationIDs.compactMap { id in
            // 不变量「操作目标 ⊆ 可见」：无筛选时门禁默认放行（逐位等价旧行为）。
            guard visibleIDSet?.contains(id) ?? true else { return nil }
            return byID[id]
        }
    }

    public var focusedItem: FileItem? {
        selection.focusID.flatMap { id in
            guard visibleIDSet?.contains(id) ?? true else { return nil }
            return itemByID[id]
        }
    }

    /// 全量条目数（`ls` 报目录总数，不受筛选影响）。
    public var itemCount: Int { page?.items.count ?? 0 }

    /// 是否处于筛选态（文本非空）。
    public var isFiltering: Bool { !filterText.isEmpty }

    /// 当前可见项 id（**存储序**，即 `page.items` 顺序——视图自行排序显示）。
    public var visibleItemIDs: [String] { visibleIDs ?? page?.items.map(\.id) ?? [] }
    public var visibleCount: Int { visibleItemIDs.count }

    /// 设置筛选文本。文本无变化直接返回；文本变化 → 重算可见集 → 收口不变量 →
    /// 与 `mutateSelection` 同款 before/after diff，**仅选择态真变时**发 onSelectionChange。
    /// 绝不发 onReload：那会每键击重排 sortedIDs + 重建标签条 + 走会话写回。
    public func setFilter(_ text: String) {
        guard text != filterText else { return }
        filterText = text
        filter = text.isEmpty ? nil : NameFilter(text)
        recomputeVisibility()
        let before = selection
        enforceVisibleInvariants()
        if before != selection { onSelectionChange?(self) }
    }

    /// 清空筛选（导航/切源时调用）。被剪掉的标记不恢复（破坏性剪枝）。
    public func clearFilter() {
        guard !filterText.isEmpty else { return }
        filterText = ""
        filter = nil
        recomputeVisibility()   // filterText 空 → 两个缓存 nil
    }

    /// 可见集的唯一写入口：**从 `page.items` 派生**（不读 `selection.items`——`load()` 里
    /// `page =` 早于 `selection.reload`，读 selection 会拿到旧值）。无筛选 → 两者 nil。
    private func recomputeVisibility() {
        guard !filterText.isEmpty, let filter else {
            visibleIDs = nil
            visibleIDSet = nil
            return
        }
        let ids = (page?.items ?? []).filter { filter.matches($0.name) }.map(\.id)
        visibleIDs = ids
        visibleIDSet = Set(ids)
    }

    /// 三条不变量的收口点（筛选激活时恒成立）：
    /// 1. 标记 ⊆ 可见——`restrictMarks` 破坏性剪枝（清空筛选不恢复）；
    /// 2. 焦点可见——被筛掉则移到最近可见项；可见集为空时焦点无处可去
    ///    （`focusIndex` 是非可选 Int），由 `operationTargets`/`focusedItem` 的可见门禁兜底；
    /// 3. 操作目标 ⊆ 可见——由上一条 + 门禁共同保证。
    private func enforceVisibleInvariants() {
        guard let visibleIDSet else { return }
        selection.restrictMarks(to: visibleIDSet)
        if let focusID = selection.focusID, !visibleIDSet.contains(focusID),
           let idx = nearestVisibleIndex(from: selection.focusIndex, in: visibleIDSet) {
            selection.setFocus(to: idx)
        }
    }

    /// 从旧索引向**后**（含自身，即索引递减）找最近可见项，找不到再向**前**（递增）。
    /// 取「最近」而非「首个」：`.end`（`moveFocus(to: itemCount - 1)`，全量索引）在筛选下
    /// 仍落到最后一个可见项；筛选时焦点自然停在光标附近的首个匹配。
    private func nearestVisibleIndex(from old: Int, in visible: Set<String>) -> Int? {
        let ids = selection.items
        guard !ids.isEmpty else { return nil }
        var i = min(max(old, 0), ids.count - 1)
        while i >= 0 {
            if visible.contains(ids[i]) { return i }
            i -= 1
        }
        i = min(max(old, 0), ids.count - 1) + 1
        while i < ids.count {
            if visible.contains(ids[i]) { return i }
            i += 1
        }
        return nil
    }

    /// Focus the item with this id if it is on the current page (used after
    /// jumping to a directory from search results).
    @discardableResult
    public func revealItem(id: String) -> Bool {
        guard let idx = selection.items.firstIndex(of: id) else { return false }
        mutateSelection { $0.setFocus(to: idx) }
        return true
    }

    public func load(preserveFocus: Bool = true, focusID: String? = nil) {
        do {
            let items = try source.listDirectory(path)
            let ids = items.map { $0.id }
            self.page = DirectoryPage(path: path, items: items)   // didSet → 按新 items 重算可见集（筛选保留）
            if let target = focusID {
                // 跨目录导航（回退/搜索）：清空标记，再按 id/name 定位到目标项。
                selection.reload(with: ids)
                applyExplicitFocus(target, items: items)
            } else {
                // 原地刷新（如 F5/F6 后）：reload(previousFocusID:) 保留焦点与标记集。
                selection.reload(with: ids,
                                 previousFocusID: preserveFocus ? selection.focusID : nil)
            }
            enforceVisibleInvariants()
            lastError = nil
        } catch let tc as TCError {
            self.page = DirectoryPage(path: path, items: [])
            selection.reload(with: [])
            enforceVisibleInvariants()
            lastError = tc
        } catch {
            self.page = DirectoryPage(path: path, items: [])
            selection.reload(with: [])
            enforceVisibleInvariants()
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
                    self.page = DirectoryPage(path: capturedPath, items: items)   // didSet → 重算可见集
                    if let target = focusID {
                        // 跨目录导航（回退/搜索）：清空标记，再按 id/name 定位到目标项。
                        self.selection.reload(with: ids)
                        self.applyExplicitFocus(target, items: items)
                    } else {
                        // 原地刷新：reload(previousFocusID:) 保留焦点与标记集。
                        self.selection.reload(with: ids,
                                              previousFocusID: preserveFocus ? previousFocusID : nil)
                    }
                    self.enforceVisibleInvariants()
                    self.lastError = nil
                case .failure(let error):
                    self.page = DirectoryPage(path: capturedPath, items: [])
                    self.selection.reload(with: [])
                    self.enforceVisibleInvariants()
                    self.lastError = error as? TCError
                        ?? TCError.unknown(error.localizedDescription)
                }
                self.onReload?(self)
            }
        }
    }

    /// 切换数据源（SFTP 连接成功后把窗格接到远端）。切源 = 换目录语义 → 清空筛选。
    public func setSource(_ newSource: FileSource, andPath newPath: TCPath) {
        loadToken &+= 1   // 使在途的旧源加载失效
        navToken &+= 1    // 使在途的旧源导航 stat 失效
        source = newSource
        path = newPath
        clearFilter()
        selection = SelectionModel()
        page = nil
        lastError = nil
        if newSource.isRemote {
            loadAsync(preserveFocus: false)
        } else {
            load(preserveFocus: false)
        }
    }

    /// 导航到新目录。**导航即清空筛选**（决策 3：筛选仅当前目录生效）；
    /// 同目录刷新走 `load`，筛选保留并重算。
    public func navigate(to newPath: TCPath, focusID: String? = nil) {
        if source.isRemote {
            // 远端 stat 有网络 RTT，不得在主线程同步执行：放进 loadQueue，
            // 回主线程经 navToken 校验后再改 path 并 loadAsync（旧导航被新导航失效）。
            navToken &+= 1
            let token = navToken
            loadQueue.async { [source] in
                let isDirectory = newPath.isRoot
                    || ((try? source.stat(newPath))?.isDirectory == true)
                DispatchQueue.main.async {
                    guard token == self.navToken, isDirectory else { return }
                    self.clearFilter()
                    self.path = newPath
                    self.loadAsync(preserveFocus: false, focusID: focusID)
                }
            }
        } else {
            guard newPath.isRoot || (try? source.stat(newPath))?.isDirectory == true else { return }
            clearFilter()
            path = newPath
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

    /// 纯选择态变更统一走此路：mutate 后先收口可见性不变量（标记剪枝/焦点落可见），
    /// 再与快照 diff，无变化不发回调（末行继续按↓ = 零渲染零滚动），有变化只发
    /// onSelectionChange（快路），不发 onReload。
    private func mutateSelection(_ mutate: (inout SelectionModel) -> Void) {
        let before = selection
        mutate(&selection)
        enforceVisibleInvariants()
        if before != selection { onSelectionChange?(self) }
    }

    public func moveFocus(to index: Int, mode: SelectionModel.MoveMode) {
        mutateSelection { $0.moveFocus(to: index, mode: mode) }
    }
    public func moveFocusBy(delta: Int, mode: SelectionModel.MoveMode) {
        mutateSelection { $0.moveFocusBy(delta: delta, mode: mode) }
    }
    public func setFocus(to index: Int) { mutateSelection { $0.setFocus(to: index) } }
    public func toggleMark() { mutateSelection { $0.toggleMark() } }
    public func toggleMark(at index: Int) { mutateSelection { $0.toggleMark(at: index) } }
    public func selectAll() { mutateSelection { $0.selectAll() } }
    public func clearMarks() { mutateSelection { $0.clearMarks() } }
}
