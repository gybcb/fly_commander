import XCTest
import Foundation
@testable import TCCore

/// 内存式源：`listDirectory` 按 pathString 字典返回（**保持给定顺序**，便于断言存储序），
/// `dirs` 里有键即视为目录（供 navigate 的 stat 校验）。
private final class FilterSource: FileSource {
    var sourceID: String
    var isRemote: Bool
    var dirs: [String: [FileItem]]
    var listError: TCError?

    init(id: String = "filter-stub", remote: Bool = false, dirs: [String: [FileItem]] = [:]) {
        sourceID = id
        isRemote = remote
        self.dirs = dirs
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        if let listError { throw listError }
        return dirs[path.pathString] ?? []
    }
    func isDirectory(_ path: TCPath) -> Bool { dirs[path.pathString] != nil }
    func stat(_ path: TCPath) throws -> FileItem? {
        guard dirs[path.pathString] != nil else { return nil }
        return FileItem(id: path.pathString, path: path, name: path.fileName,
                        isDirectory: true, size: 0, modificationDate: .distantPast,
                        isHidden: false, isReadOnly: false, isExecutable: true)
    }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

private func file(_ name: String, at dir: String = "/x") -> FileItem {
    FileItem(id: "\(dir)/\(name)", path: TCPath("\(dir)/\(name)"), name: name,
             isDirectory: false, size: 1, modificationDate: .distantPast,
             isHidden: false, isReadOnly: false, isExecutable: false)
}

private func names(_ ids: [String]) -> [String] {
    ids.map { ($0 as NSString).lastPathComponent }
}

final class FilePaneFilterTests: XCTestCase {

    private func makePane(_ names: [String], path: String = "/x") -> FilePane {
        let src = FilterSource(dirs: [path: names.map { file($0, at: path) }])
        let pane = FilePane(id: .left, source: src, startPath: TCPath(path))
        pane.load()
        return pane
    }

    // MARK: - 无筛选回归等价（门禁默认放行）

    /// 无筛选时 operationTargets/focusedItem/selectAll/可见集与旧行为逐位一致。
    /// 变异：把门禁写成 `visibleIDSet?.contains(id) ?? false` → 无筛选下全空，本用例红。
    func testNoFilterBehaviorUnchanged() {
        let pane = makePane(["a.pdf", "b.txt", "c.md"])
        XCTAssertFalse(pane.isFiltering)
        XCTAssertEqual(pane.filterText, "")
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.pdf", "b.txt", "c.md"], "存储序")
        XCTAssertEqual(pane.visibleCount, 3)
        XCTAssertEqual(pane.itemCount, 3)
        XCTAssertEqual(pane.focusedItem?.name, "a.pdf")
        XCTAssertEqual(pane.operationTargets.map(\.name), ["a.pdf"], "缺省=焦点项")
        pane.selectAll()
        XCTAssertEqual(pane.operationTargets.map(\.name), ["a.pdf", "b.txt", "c.md"])
        pane.clearMarks()
        pane.moveFocus(to: 1, mode: .simple)
        XCTAssertEqual(pane.focusedItem?.name, "b.txt")
    }

    // MARK: - 匹配投影

    /// 子串筛选大小写不敏感；`*` 切换通配符全串锚定。
    /// 变异：把 setFilter 里的 `filter.matches(item.name)` 改成 `item.name == text` → 本用例红。
    func testFilterProjectsVisibleSet() {
        let pane = makePane(["a.pdf", "b.txt", "c.TXT", "d"])
        pane.setFilter("txt")
        XCTAssertTrue(pane.isFiltering)
        XCTAssertEqual(names(pane.visibleItemIDs), ["b.txt", "c.TXT"])
        pane.setFilter("*.pdf")
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.pdf"])
        pane.setFilter("?")
        XCTAssertEqual(names(pane.visibleItemIDs), ["d"], "单字符通配符全串锚定")
        XCTAssertEqual(pane.itemCount, 4, "itemCount 保持全量")
    }

    /// 可见集按 `page.items` **存储序**返回（视图自行排序）。
    /// 变异：把 visibleItemIDs 改成排序返回 → 本用例红。
    func testVisibleItemIDsKeepStorageOrder() {
        let pane = makePane(["z.txt", "a.txt"])
        pane.setFilter("txt")
        XCTAssertEqual(names(pane.visibleItemIDs), ["z.txt", "a.txt"])
    }

    /// setFilter 只发 onSelectionChange（且仅选择态真变时），绝不发 onReload。
    /// 变异：把 setFilter 改成 `onReload?(self)` → reloads 非 0，本用例红；
    /// 去掉 before/after diff 改为一律发 → 第二次 setFilter 也发，本用例红。
    func testSetFilterFiresSelectionChangeOnlyOnRealChange() {
        let pane = makePane(["a.pdf", "b.txt"])
        var reloads = 0, selChanges = 0
        pane.onReload = { _ in reloads += 1 }
        pane.onSelectionChange = { _ in selChanges += 1 }
        pane.setFilter("txt")                 // 焦点 a.pdf 被筛掉 → 焦点移动 = 选择态真变
        XCTAssertEqual(selChanges, 1)
        XCTAssertEqual(reloads, 0, "setFilter 绝不发 onReload（每键击重排 + 重建标签条 + 会话写回）")
        pane.setFilter("txt")                 // 文本无变化 → 直接返回
        XCTAssertEqual(selChanges, 1)
        pane.setFilter("")                    // 放宽：选择态无变化
        XCTAssertEqual(selChanges, 1)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(pane.visibleCount, 2)
    }

    // MARK: - 空可见集

    /// 无命中：operationTargets == []、focusedItem == nil、selectAll 标空、计数 0。
    /// 变异：operationTargets/focusedItem 去掉可见门禁 → 本用例红（返回被筛掉的焦点项）。
    func testEmptyVisibleSetGatesEverything() {
        let pane = makePane(["a.pdf", "b.txt"])
        pane.selectAll()
        pane.setFilter("zzz")
        XCTAssertEqual(pane.visibleCount, 0)
        XCTAssertTrue(pane.visibleItemIDs.isEmpty)
        XCTAssertEqual(pane.operationTargets, [])
        XCTAssertNil(pane.focusedItem)
        XCTAssertEqual(pane.itemCount, 2, "ls 仍报目录总数")
        pane.selectAll()                       // 全量标记 → 收口后为空
        XCTAssertTrue(pane.selection.marked.isEmpty)
        XCTAssertEqual(pane.operationTargets, [])
    }

    // MARK: - 标记剪枝（不恢复）

    /// 筛掉已标记项 → marked 破坏性剪枝；清空筛选**不恢复**。
    /// 变异：删掉 enforceVisibleInvariants 里的 `restrictMarks(to:)` → 清空后仍是 3 个标记，本用例红。
    func testMarksPrunedAndNotRestored() {
        let pane = makePane(["a.pdf", "b.txt", "c.md"])
        pane.selectAll()
        XCTAssertEqual(pane.operationTargets.count, 3)
        pane.setFilter("a")                    // 仅 a.pdf 命中
        XCTAssertEqual(names(pane.selection.markedIDs), ["a.pdf"])
        XCTAssertEqual(pane.operationTargets.map(\.name), ["a.pdf"])
        pane.setFilter("")                     // 清空筛选：剪掉的标记不恢复
        XCTAssertEqual(names(pane.selection.markedIDs), ["a.pdf"])
        XCTAssertEqual(pane.visibleCount, 3)
    }

    /// `.range` 跨过隐藏项：区间内隐藏项不进 marked（不变量在 mutateSelection 收口）。
    /// 变异：删掉 mutateSelection 里的 enforceVisibleInvariants() → marked 含 c.md，本用例红。
    func testRangeSelectionSkipsHidden() {
        let pane = makePane(["a.pdf", "b.txt", "c.md", "d.txt"])
        pane.setFilter("txt")                  // 可见 b.txt(1), d.txt(3)
        XCTAssertEqual(pane.focusedItem?.name, "b.txt", "焦点被筛掉 → 落最近可见（向后无 → 向前）")
        pane.moveFocus(to: 3, mode: .range)    // 区间 1..3 含隐藏 c.md
        XCTAssertEqual(names(pane.selection.markedIDs), ["b.txt", "d.txt"])
        XCTAssertEqual(pane.operationTargets.map(\.name), ["b.txt", "d.txt"])
    }

    // MARK: - 焦点落点

    /// 焦点被筛掉 → 先向**后**（索引递减）找最近可见项。
    /// 变异：把 nearestVisibleIndex 改成向前优先 → 落到 e.pdf，本用例红。
    func testFocusMovesToNearestVisibleBackwardFirst() {
        let pane = makePane(["a.pdf", "b.txt", "c.pdf", "d.txt", "e.pdf"])
        pane.moveFocus(to: 3, mode: .simple)   // focus d.txt
        pane.setFilter("pdf")                  // 可见 a.pdf(0), c.pdf(2), e.pdf(4)
        XCTAssertEqual(pane.focusedItem?.name, "c.pdf")
    }

    /// 向后无可见项时再向前找（焦点在首项且首项被筛掉）。
    /// 变异：去掉向前扫描 → focusedItem 为 nil，本用例红。
    func testFocusMovesForwardWhenNothingBehind() {
        let pane = makePane(["z.log", "a.txt"])
        pane.setFilter("txt")
        XCTAssertEqual(pane.focusedItem?.name, "a.txt")
    }

    /// `.end`（全量末索引）在筛选下落到**最后一个可见项**（取最近的动机）。
    /// 变异：把 enforce 改成「移到首个可见项」→ 落到 a.pdf，本用例红。
    func testEndLandsOnLastVisibleItem() {
        let pane = makePane(["a.pdf", "b.txt", "c.pdf", "d.txt"])
        pane.setFilter("pdf")                  // 可见 a.pdf(0), c.pdf(2)
        pane.moveFocus(to: pane.itemCount - 1, mode: .simple)   // .end = 索引 3（隐藏）
        XCTAssertEqual(pane.focusedItem?.name, "c.pdf")
    }

    // MARK: - 导航清空 / 刷新保留

    /// 同目录刷新（load）保留筛选，并按新 items 重算可见集。
    /// 变异：在 load 里调用 clearFilter() → filterText 变空，本用例红；
    /// 把 recomputeVisibility 改成读 selection.items → 刷新后可见集仍是旧 id，本用例红。
    func testLoadKeepsFilterAndRecomputes() {
        let src = FilterSource(dirs: ["/x": [file("a.txt"), file("b.md")]])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/x"))
        pane.load()
        pane.setFilter("txt")
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt"])
        src.dirs["/x"] = [file("c.txt"), file("d.md"), file("e.txt")]
        pane.load()                            // 同目录刷新
        XCTAssertEqual(pane.filterText, "txt", "刷新保留筛选")
        XCTAssertEqual(names(pane.visibleItemIDs), ["c.txt", "e.txt"], "按新 items 重算")
        XCTAssertEqual(pane.itemCount, 3)
    }

    /// 导航清空筛选（决策 3：仅当前目录生效）。
    /// 变异：navigate 同步分支去掉 clearFilter() → filterText 仍 "txt"，本用例红。
    func testNavigateClearsFilter() {
        let src = FilterSource(dirs: ["/x": [file("a.txt"), file("b.md")],
                                      "/x/sub": [file("c.txt", at: "/x/sub")]])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/x"))
        pane.load()
        pane.setFilter("txt")
        pane.navigate(to: TCPath("/x/sub"))
        XCTAssertEqual(pane.path.pathString, "/x/sub")
        XCTAssertEqual(pane.filterText, "")
        XCTAssertFalse(pane.isFiltering)
        XCTAssertEqual(pane.visibleCount, 1, "无筛选 → 全量")
    }

    /// 远端导航（stat 在后台 + 回主线程 hop）同样清空筛选。
    /// 变异：远端回主线程分支去掉 clearFilter() → filterText 仍 "txt"，本用例红。
    func testRemoteNavigateClearsFilter() {
        let src = FilterSource(id: "sftp://h:2222", remote: true,
                               dirs: ["/x": [file("a.txt"), file("b.md")],
                                      "/x/sub": [file("c.txt", at: "/x/sub")]])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("sftp://h:2222/x"))
        pane.load()
        pane.setFilter("txt")
        let done = expectation(description: "remote navigate done")
        pane.onReload = { _ in done.fulfill() }
        pane.navigate(to: TCPath("sftp://h:2222/x/sub"))
        wait(for: [done], timeout: 5)
        XCTAssertEqual(pane.path.pathString, "/x/sub")
        XCTAssertEqual(pane.filterText, "")
        XCTAssertEqual(pane.visibleCount, 1)
    }

    /// 切源（setSource）清空筛选。
    /// 变异：setSource 去掉 clearFilter() → filterText 仍 "txt"，本用例红。
    func testSetSourceClearsFilter() {
        let pane = makePane(["a.txt"])
        pane.setFilter("txt")
        let other = FilterSource(dirs: ["/y": [file("z.md", at: "/y")]])
        pane.setSource(other, andPath: TCPath("/y"))
        XCTAssertEqual(pane.filterText, "")
        XCTAssertFalse(pane.isFiltering)
        XCTAssertEqual(pane.visibleCount, 1)
    }

    // MARK: - 加载失败

    /// 源抛错：可见集为空、不残留过期 id、标记清空、不崩；筛选文本保留。
    /// 变异：失败分支保留旧 page（不赋空 DirectoryPage）→ visibleCount 非 0，本用例红。
    func testLoadFailureLeavesNoStaleVisibility() {
        let src = FilterSource(dirs: ["/x": [file("a.txt"), file("b.txt")]])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/x"))
        pane.load()
        pane.setFilter("txt")
        pane.selectAll()
        XCTAssertEqual(pane.selection.marked.count, 2)

        src.listError = TCError.permissionDenied("/x")
        pane.load()
        XCTAssertNotNil(pane.lastError)
        XCTAssertEqual(pane.itemCount, 0)
        XCTAssertEqual(pane.visibleCount, 0)
        XCTAssertTrue(pane.visibleItemIDs.isEmpty, "不残留过期 id")
        XCTAssertTrue(pane.selection.marked.isEmpty)
        XCTAssertEqual(pane.filterText, "txt", "加载失败不清筛选")
        XCTAssertNil(pane.focusedItem)
        XCTAssertEqual(pane.operationTargets, [])

        src.listError = nil
        src.dirs["/x"] = [file("n.txt")]
        pane.load()                            // 恢复后按新 items 重算
        XCTAssertEqual(names(pane.visibleItemIDs), ["n.txt"])
    }

    // MARK: - loadAsync（后台加载分支）

    /// loadAsync 成功：筛选保留 + 按新 items 重算可见集。
    /// 变异：loadAsync 成功分支去掉 enforceVisibleInvariants() → 焦点/标记不随可见集收口，本用例红。
    func testLoadAsyncKeepsFilterAndRecomputes() {
        let src = FilterSource(id: "sftp://h:2222", remote: true,
                               dirs: ["/x": [file("a.txt"), file("b.md")]])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("sftp://h:2222/x"))
        pane.setFilter("txt")
        src.dirs["/x"] = [file("c.txt"), file("d.md"), file("e.txt")]
        let done = expectation(description: "loadAsync done")
        pane.onReload = { _ in done.fulfill() }
        pane.loadAsync()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(pane.filterText, "txt")
        XCTAssertEqual(names(pane.visibleItemIDs), ["c.txt", "e.txt"])
        XCTAssertEqual(pane.focusedItem?.name, "c.txt")
    }

    /// loadAsync 失败：可见集清空、不崩。
    /// 变异：失败分支不把 page 置空 → 可见集残留，本用例红。
    func testLoadAsyncFailureClearsVisibility() {
        let src = FilterSource(id: "sftp://h:2222", remote: true,
                               dirs: ["/x": [file("a.txt"), file("b.md")]])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("sftp://h:2222/x"))
        pane.load()
        pane.setFilter("txt")
        src.listError = TCError.permissionDenied("/x")
        let done = expectation(description: "loadAsync failed")
        pane.onReload = { _ in done.fulfill() }
        pane.loadAsync()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(pane.visibleCount, 0)
        XCTAssertTrue(pane.visibleItemIDs.isEmpty)
        XCTAssertNil(pane.focusedItem)
        XCTAssertEqual(pane.operationTargets, [])
        XCTAssertEqual(pane.filterText, "txt")
    }
}
