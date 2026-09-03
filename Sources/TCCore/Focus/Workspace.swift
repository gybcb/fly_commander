import Foundation

/// 操作状态通道（Plan B：结构 key 化）。
///
/// 内核/传输层**只发 `L10nKey` + 结构化参数**，不再产中文成品串：
/// - `label`/`args` → 显示边界（`MainViewController.statusText(for:)`）用 `t(label, args…)` 展开；
/// - `warningLines` → 已由边界组装好的**成品串**（警告在引擎深层逐条产生，穿三层只为最终 join
///   收益不抵成本，故结构化原料 `(name, TCError)` 在 CommandRouter/TransferEngine 就地组装）；
/// - `failed` → 携带 `TCError` 本体，显示时经 `tcErrorDisplay` 现取，天然随语言。
public enum OperationState: Equatable {
    case idle
    case running(label: L10nKey, args: [String], progress: Double)
    case done(label: L10nKey, args: [String], warningLines: [String])
    case failed(TCError)
}

public final class Workspace {
    public let leftTabs: TabGroup
    public let rightTabs: TabGroup
    public private(set) var active: PaneID

    public var onActiveChange: ((Workspace) -> Void)?
    public var onOperationState: ((OperationState) -> Void)?
    /// 命令栏 copy/move（等价 F5/F6）：app 层接 CommandRouter 的传输路径（远端走后台）。
    public var onCommandTransfer: ((CommandID) -> Void)?
    /// 命令栏需要状态栏提示时的文本落点（不经过 OperationState 通道）。
    public var onCommandStatus: ((String) -> Void)?
    /// 命令栏 view/edit 的 app 层入口（复用菜单同款行为）。
    public var onCommandView: ((FileItem) -> Void)?
    public var onCommandEdit: ((FileItem) -> Void)?

    public init(left: TabGroup, right: TabGroup, active: PaneID = .left) {
        self.leftTabs = left
        self.rightTabs = right
        self.active = active
    }

    /// 单标签便捷构造（app 启动 & 既有测试常用）：左右各包成单标签 TabGroup。
    public convenience init(left: FilePane, right: FilePane, active: PaneID = .left) {
        self.init(left: TabGroup(side: .left, panes: [left]),
                  right: TabGroup(side: .right, panes: [right]),
                  active: active)
    }

    public var activeTab: TabGroup { active == .left ? leftTabs : rightTabs }
    public var inactiveTab: TabGroup { active == .left ? rightTabs : leftTabs }
    /// 活动侧当前标签的 pane（命令流唯一入口，语义=原"活动窗格"）。
    public var activePane: FilePane { activeTab.activePane }
    /// 对侧当前标签的 pane（=原"另一窗格"）。
    public var inactivePane: FilePane { inactiveTab.activePane }

    public func activate(_ id: PaneID) {
        guard active != id else { return }
        active = id
        onActiveChange?(self)
    }

    public func switchActive() { activate(active == .left ? .right : .left) }

    /// 活动侧切到下一个标签（wrap）；标签变化时触发 onActiveChange。
    public func nextTab() {
        if activeTab.step(1) { onActiveChange?(self) }
    }

    /// 活动侧切到上一个标签（wrap）。
    public func prevTab() {
        if activeTab.step(-1) { onActiveChange?(self) }
    }

    public func operationState(_ s: OperationState) { onOperationState?(s) }
}
