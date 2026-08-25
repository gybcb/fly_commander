import Foundation

/// 一侧（左/右）的一组标签页。每侧至少 1 个标签——关最后一个时 `close` 返回 nil 拒绝。
/// 纯数据结构（持有 [FilePane] + activeIndex），无 AppKit、无 IO，可单测。
public final class TabGroup {
    public let side: PaneID
    public private(set) var panes: [FilePane]
    public private(set) var activeIndex: Int

    public init(side: PaneID, panes: [FilePane], activeIndex: Int = 0) {
        precondition(!panes.isEmpty, "TabGroup 至少 1 个 pane")
        precondition((0..<panes.count).contains(activeIndex), "activeIndex 越界")
        self.side = side
        self.panes = panes
        self.activeIndex = activeIndex
    }

    public var count: Int { panes.count }
    public var activePane: FilePane { panes[activeIndex] }

    /// 追加一个新标签并激活它；返回该 pane。
    @discardableResult
    public func add(_ pane: FilePane) -> FilePane {
        panes.append(pane)
        activeIndex = panes.count - 1
        return pane
    }

    /// 关闭 `index` 标签。唯一标签或越界 → 返回 nil（不改动）。
    /// 成功返回被移除的 pane（供调用方做视图层清理）；关闭后激活相邻标签：
    /// 关了活动标签→右侧邻居（无则最末）；关了活动左侧→index 减一；关了活动右侧→index 不变。
    @discardableResult
    public func close(at index: Int) -> FilePane? {
        guard panes.count > 1, (0..<panes.count).contains(index) else { return nil }
        let removed = panes.remove(at: index)
        if index < activeIndex { activeIndex -= 1 }
        if activeIndex >= panes.count { activeIndex = panes.count - 1 }
        return removed
    }

    /// 相对当前激活标签偏移 `offset`（wrap 环绕）。返回 `activeIndex` 是否变化；
    /// 单标签或 offset 落到自身时返回 false（no-op）。
    @discardableResult
    public func step(_ offset: Int) -> Bool {
        guard panes.count > 1 else { return false }
        let n = panes.count
        let target = ((activeIndex + offset) % n + n) % n
        guard target != activeIndex else { return false }
        activeIndex = target
        return true
    }

    /// 绝对激活（clamp 到合法范围）。
    public func activate(index: Int) {
        activeIndex = min(max(index, 0), panes.count - 1)
    }
}
