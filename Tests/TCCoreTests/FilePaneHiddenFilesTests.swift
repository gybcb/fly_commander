import XCTest
import Foundation
@testable import TCCore

/// 内存式源（HiddenSourceTests 独立桩——FilePaneFilterTests 的 FilterSource 文件私有）。
private final class HiddenSource: FileSource {
    var sourceID = "hidden-stub"
    var isRemote = false
    var dirs: [String: [FileItem]]
    init(dirs: [String: [FileItem]]) { self.dirs = dirs }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirs[path.pathString] ?? [] }
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
    func makeDirectory(at path: TCPath) throws {}
    func removeItem(at path: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

private func item(_ name: String, at dir: String = "/x", hidden: Bool = false) -> FileItem {
    FileItem(id: "\(dir)/\(name)", path: TCPath("\(dir)/\(name)"), name: name,
             isDirectory: false, size: 1, modificationDate: .distantPast,
             isHidden: hidden, isReadOnly: false, isExecutable: false)
}

private func names(_ ids: [String]) -> [String] {
    ids.map { ($0 as NSString).lastPathComponent }
}

/// `FilePane.showHidden` 闸门回归。总变异锚：把 recomputeVisibility 的隐藏闸门条件
/// （`showHidden || !item.isHidden`）改成恒真 → 本文件除「默认全显」「nil 旧语义锁」
/// 外的全部断言红。
final class FilePaneHiddenFilesTests: XCTestCase {

    private func makePane(_ items: [FileItem], showHidden: Bool = true) -> FilePane {
        let src = HiddenSource(dirs: ["/x": items])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/x"))
        pane.showHidden = showHidden
        pane.load()
        return pane
    }

    private var fixture: [FileItem] {
        [item("a.txt"), item(".dot", hidden: true), item("b.md"), item(".git", hidden: true)]
    }

    /// 闸门关闭（showHidden=false）：可见集排除 hidden，itemCount 保持全量。
    /// 变异：recompute 无视 showHidden → visibleItemIDs 含 .dot，本用例红。
    func testHiddenExcludedWhenGateClosed() {
        let pane = makePane(fixture, showHidden: false)
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt", "b.md"], "存储序保持")
        XCTAssertEqual(pane.visibleCount, 2)
        XCTAssertEqual(pane.itemCount, 4, "ls 仍报全量")
    }

    /// 内核缺省（showHidden=true）：hidden 项照旧全显（旧行为零扰动）。
    /// 变异：缺省值写成 false → 本用例红。
    func testDefaultShowsHidden() {
        let pane = makePane(fixture)
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt", ".dot", "b.md", ".git"])
    }

    /// 双闸门组合：隐藏闸 + 文本闸同时生效，条目须两者都过。
    /// 变异：组合处 AND 写成 OR → .dot 泄漏（文本匹配）或 b.md 丢失，本用例红。
    func testGateComposesWithTextFilter() {
        let pane = makePane(fixture + [item(".d.txt", hidden: true)], showHidden: false)
        pane.setFilter("txt")
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt"], ".d.txt 文本匹配但被隐藏闸拦下")
        pane.setFilter("")
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt", "b.md"], "清空文本 → 只剩隐藏闸")
    }

    /// 关闸破坏性剪掉 hidden 项的标记；**开闸不恢复**（与文本筛选剪枝同构，决策 5）。
    /// 变异：删掉 didSet 里的 enforceVisibleInvariants() → 关闸后 marked 仍含 .dot，本用例红。
    func testGateClosePrunesHiddenMarks() {
        let pane = makePane(fixture)
        pane.selectAll()
        XCTAssertEqual(pane.operationTargets.count, 4)
        pane.showHidden = false
        XCTAssertEqual(names(pane.selection.markedIDs), ["a.txt", "b.md"], "hidden 标记被剪")
        XCTAssertEqual(pane.operationTargets.map(\.name), ["a.txt", "b.md"], "操作目标 ⊆ 可见")
        pane.showHidden = true
        XCTAssertEqual(names(pane.selection.markedIDs), ["a.txt", "b.md"], "开闸不恢复（破坏性）")
    }

    /// 焦点在 hidden 项时关闸 → 焦点收口到最近可见项（向后优先）。
    /// 变异：删掉 didSet 的 enforceVisibleInvariants() → focusedItem nil（门禁拦下焦点），本用例红。
    func testGateCloseRelocatesFocus() {
        let pane = makePane(fixture)
        pane.moveFocus(to: 1, mode: .simple)          // 焦点 .dot（hidden）
        XCTAssertEqual(pane.focusedItem?.name, ".dot")
        pane.showHidden = false
        XCTAssertEqual(pane.focusedItem?.name, "a.txt", "向后最近可见")
    }

    /// 闸门切换 = 纯选择态快路：仅选择态真变才发 onSelectionChange，绝不发 onReload
    /// （与 setFilter 同契约；onReload 是重建标签条+会话写回的全量路）。
    /// 变异：didSet 改发 onReload → reloads 非 0 本用例红；去掉 before/after diff
    /// → 第二次关闸（同值 no-op）或开闸无变化时也发，本用例红。
    func testGateToggleFiresSelectionChangeOnly() {
        let pane = makePane(fixture)
        var reloads = 0, selChanges = 0
        pane.onReload = { _ in reloads += 1 }
        pane.onSelectionChange = { _ in selChanges += 1 }
        pane.showHidden = true                          // 同值 → didSet guard 拦下
        XCTAssertEqual(selChanges, 0)
        pane.moveFocus(to: 1, mode: .simple)            // 焦点移到 .dot（hidden）
        selChanges = 0                                  // 基线归零，只数闸门切换的回调
        pane.showHidden = false                         // 焦点 .dot 被收口到 a.txt = 真变
        XCTAssertEqual(selChanges, 1)
        pane.showHidden = true                          // 放宽：焦点 a.txt 仍可见 → 无变化
        XCTAssertEqual(selChanges, 1, "无实际变化 = 零回调")
        XCTAssertEqual(reloads, 0, "闸门切换绝不发 onReload")
    }

    /// 旧语义回归锁：showHidden=true 且无文本筛选 → 两缓存必为 nil（「显示全部」由
    /// nil 表达，所有 `?? true` 消费端零扰动）。非 nil 空缓存与 nil 语义不同——
    /// 空目录+闸门全放行也必须 nil。
    /// 变异：recompute 的 nil 分支改成恒等非 nil 全量数组 → 本用例红（依赖 internal
    /// 缓存直读；@testable 可达）。
    func testNilCacheSemanticsPreservedWhenBothGatesOpen() {
        let pane = makePane(fixture)
        XCTAssertNil(pane.visibleIDs, "全放行必须 nil（旧语义）")
        XCTAssertNil(pane.visibleIDSet)
        pane.setFilter("zzz")                    // 文本闸生效 → 非 nil 空
        XCTAssertNotNil(pane.visibleIDs)
        pane.setFilter("")                       // 回全放行 → 复 nil
        XCTAssertNil(pane.visibleIDs)
        pane.showHidden = false                  // 隐藏闸生效 → 非 nil
        XCTAssertNotNil(pane.visibleIDs)
    }

    /// 关闸后同目录刷新（load）闸门仍生效（didSet 的 recompute 与 page didSet 的
    /// recompute 汇于同一函数）。
    /// 变异：load 绕过 recomputeVisibility 直接置 nil 缓存 → 刷新后 hidden 泄漏，本用例红。
    func testReloadKeepsGate() {
        let src = HiddenSource(dirs: ["/x": fixture])
        let pane = FilePane(id: .left, source: src, startPath: TCPath("/x"))
        pane.showHidden = false
        pane.load()
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt", "b.md"])
        src.dirs["/x"] = fixture + [item(".new", hidden: true)]
        pane.load()
        XCTAssertEqual(names(pane.visibleItemIDs), ["a.txt", "b.md"], "刷新按新 items 重算，闸仍关")
    }
}
