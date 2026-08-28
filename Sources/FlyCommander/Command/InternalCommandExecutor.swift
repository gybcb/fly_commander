import Foundation
import AppKit
import TCCore

/// 底部命令栏的"删除请求"（app 层统一走确认流：本地废纸篓 / 远端直接删）。
struct InternalDeleteRequest {
    let pane: FilePane
    let targets: [FileItem]
}

/// TC 式内部命令执行器（仅内部命令，不做 shell 透传）。
/// 所有 UI 副作用（弹窗/后台删除/连接窗）都注入成钩子，单测用 fake 捕获。
final class InternalCommandExecutor {
    let workspace: Workspace
    let engine: OperationEngine

    /// 删除入口（app 侧接 MainViewController 的确认+执行流）。
    var onDelete: ((_ request: InternalDeleteRequest) -> Void)?
    /// sftp 命令入口（弹连接窗；host/port 可预填，nil=不预填）。
    var onConnectSFTP: ((_ host: String?, _ port: UInt16?) -> Void)?
    /// smb 命令入口（弹连接窗；server/share/user 可预填，nil=不预填）。
    var onConnectSMB: ((_ server: String?, _ share: String?, _ user: String?) -> Void)?
    /// theme 命令入口（弹主题窗）。
    var onOpenTheme: (() -> Void)?
    /// tab new 命令入口（app 侧建标签）。
    var onNewTab: (() -> Void)?
    /// tab close 命令入口（app 侧关活动标签）；返回 false=最后一个标签无法关。
    var onCloseTab: (() -> Bool)?

    init(workspace: Workspace, engine: OperationEngine) {
        self.workspace = workspace
        self.engine = engine
    }

    // MARK: - 命令清单

    static let helpText: String = [
        "可用命令（TC 式内部命令，仅作用于窗格，不做 shell 透传）：",
        "  cd [路径]            进入目录（缺省回主目录；远程窗格仅收 sftp://host:port/路径）",
        "  ls                   回显活动窗格条目数",
        "  mkdir 名称            新建目录（本地/远程均可）",
        "  copy                 把活动窗格标记项复制到另一窗格（等价 F5）",
        "  move                 把活动窗格标记项移动到另一窗格（等价 F6）",
        "  del [项…]             删除（缺省=焦点项；* = 全部；本地进废纸篓、远程直接删，均有确认）",
        "  view                 预览焦点文件（远程暂不支持）",
        "  edit                 用外部编辑器打开焦点文件（远程暂不支持）",
        "  sftp [host[:port]]   打开 SFTP 连接窗（可预填主机/端口）",
        "  smb [server[/share]] [user]  打开 SMB 连接窗（可预填服务器/共享/用户）",
        "  tab new            新建标签（活动侧；缺省 tab 同义）",
        "  tab close          关闭活动标签（每侧保底 1 个，最后一个不可关）",
        "  theme                打开主题窗（外观/强调色/文件类型配色）",
        "  help                 显示本帮助",
    ].joined(separator: "\n")

    // MARK: - 入口

    /// 执行一行命令，返回中文回显文本（nil = 无输出）。
    @discardableResult
    func execute(line: String) -> String? {
        let cmd: ParsedCommand
        do { cmd = try CommandLineParser.parse(line) }
        catch let e as CommandLineError {
            return e == .empty ? nil : "语法错误：请检查引号是否闭合"
        }
        catch { return "语法错误" }

        switch cmd.name {
        case "cd": return doCd(cmd.args)
        case "ls": return doLs()
        case "mkdir": return doMkdir(cmd.args)
        case "copy": runTransfer(.copy); return "已发起复制，详见状态栏"
        case "move": runTransfer(.move); return "已发起移动，详见状态栏"
        case "del": return doDel(cmd.args)
        case "view": return doView()
        case "edit": return doEdit()
        case "sftp": return doSFTP(cmd.args)
        case "smb": return doSMB(cmd.args)
        case "tab": return doTab(cmd.args)
        case "theme": onOpenTheme?(); return "已打开主题窗"
        case "help": return Self.helpText
        default: return "未知命令：\(cmd.name)（输入 help 查看命令清单）"
        }
    }

    // MARK: - 各命令

    private func doCd(_ args: [String]) -> String? {
        let pane = workspace.activePane
        let target: TCPath
        if args.isEmpty {
            if pane.source.isRemote {
                // 回远端 home（SFTPSource 用 homeDirectory；SMBSource 用 homePath）
                if let sftp = pane.source as? SFTPSource {
                    target = TCPath("sftp://\(hostOf(pane.path))\(sftp.homeDirectory)")
                } else if let smb = pane.source as? SMBSource {
                    target = smb.homePath
                } else {
                    target = TCPath("sftp://\(hostOf(pane.path))/")
                }
            } else {
                target = TCPath("~")
            }
        } else {
            let raw = args[0]
            if pane.source.isRemote {
                target = TCPath(raw)
                if !target.isRemote {
                    return "远程窗格只接受 sftp://host:port/路径 形式的目标"
                }
            } else {
                if TCPath(raw).isRemote {
                    return "本地窗格不能 cd 到 sftp:// 路径（先用 sftp 命令连接）"
                }
                target = raw.hasPrefix("/") ? TCPath(raw)
                    : TCPath((pane.path.url.path as NSString).appendingPathComponent(raw))
            }
        }
        if pane.source.isRemote {
            // navigate 的远端 stat 已异步化，path 不会同步变化，不能靠 path 判定成败；
            // 命令栏回显需要同步结果，这里自己 stat 校验一次（同步网络 RTT 与旧同步 navigate 同价）。
            guard (try? pane.source.stat(target))?.isDirectory == true else {
                return "无法进入：\(target.displayString())（不存在或不是目录）"
            }
            pane.navigate(to: target)
            return "已进入 \(target.displayString())"
        }
        let before = pane.path
        pane.navigate(to: target)
        return pane.path == before ? "无法进入：\(target.displayString())（不存在或不是目录）"
                                   : "已进入 \(pane.path.displayString())"
    }

    private func hostOf(_ path: TCPath) -> String {
        guard let host = path.url.host, let port = path.url.port else { return "" }
        return "\(host):\(port)"
    }

    private func doLs() -> String? {
        let pane = workspace.activePane
        if let err = pane.lastError {
            return "目录读取失败：\(err.message)"
        }
        return "\(pane.path.displayString())：\(pane.itemCount) 个条目"
    }

    private func doMkdir(_ args: [String]) -> String? {
        guard args.count == 1, !args[0].isEmpty else { return "用法：mkdir 名称" }
        let pane = workspace.activePane
        let before = pane.path
        do {
            let dir = try engine.performMakeDirectory(args[0], in: before, source: pane.source)
            pane.load()
            return "已新建目录 \(dir.displayString())"
        } catch let e as TCError {
            return "新建失败：\(e.message)"
        } catch {
            return "新建失败：\(error.localizedDescription)"
        }
    }

    private func runTransfer(_ id: CommandID) {
        let pane = workspace.activePane
        guard !pane.operationTargets.isEmpty else {
            setStatus("没有可传输的项（先用空格/方向键选择）")
            return
        }
        workspace.onCommandTransfer?(id)
    }

    private func setStatus(_ s: String) {
        workspace.onCommandStatus?(s)
    }

    private func doDel(_ args: [String]) -> String? {
        let pane = workspace.activePane
        let targets: [FileItem]
        if args.isEmpty {
            targets = pane.operationTargets
        } else if args == ["*"] {
            targets = pane.page?.items ?? []
        } else {
            let byID = pane.itemByID
            let found = args.compactMap { byID[$0] }
            if found.count != args.count {
                let missing = args.filter { byID[$0] == nil }
                return "未找到：\(missing.joined(separator: " "))（当前目录下无此项）"
            }
            targets = found
        }
        guard !targets.isEmpty else { return "没有要删除的项" }
        onDelete?(InternalDeleteRequest(pane: pane, targets: targets))
        return "已发起删除 \(targets.count) 项（等待确认）"
    }

    private func doView() -> String? {
        guard let item = workspace.activePane.focusedItem else { return "没有焦点项" }
        if item.isDirectory { return "目录不可预览" }
        if workspace.activePane.source.isRemote {
            return "远程暂不支持预览，请先下载到本地"
        }
        workspace.onCommandView?(item)
        return nil
    }

    private func doEdit() -> String? {
        guard let item = workspace.activePane.focusedItem else { return "没有焦点项" }
        if item.isDirectory { return "目录不可编辑" }
        if workspace.activePane.source.isRemote {
            return "远程暂不支持外部编辑，请先下载到本地"
        }
        workspace.onCommandEdit?(item)
        return nil
    }

    private func doSFTP(_ args: [String]) -> String? {
        guard args.count <= 1 else { return "用法：sftp [host[:port]]" }
        var host: String?
        var port: UInt16?
        if let arg = args.first, !arg.isEmpty {
            let parts = arg.split(separator: ":", maxSplits: 1)
            host = String(parts[0])
            if parts.count == 2 { port = UInt16(parts[1]) }
        }
        onConnectSFTP?(host, port)
        return host != nil ? "已打开连接窗（主机：\(host!)）" : "已打开 SFTP 连接窗"
    }

    private func doSMB(_ args: [String]) -> String? {
        guard args.count <= 2 else { return "用法：smb [server[/share]] [user]" }
        var server: String?, share: String?, user: String?
        if let first = args.first, !first.isEmpty {
            let seg = first.split(separator: "/", maxSplits: 1)
            // split 对全空段（"/"、"//"）返回 []，须先取 first 再取值，防越界崩溃。
            if let s0 = seg.first {
                server = String(s0)
                if seg.count == 2 { share = String(seg[1]) }
            }
        }
        if args.count == 2, !args[1].isEmpty { user = args[1] }
        onConnectSMB?(server, share, user)
        return server != nil ? "已打开连接窗（服务器：\(server!)）" : "已打开 SMB 连接窗"
    }

    private func doTab(_ args: [String]) -> String? {
        switch args.first?.lowercased() {
        case "new", nil:
            onNewTab?()
            return "已新建标签"
        case "close":
            if let closed = onCloseTab?(), closed { return "已关闭标签" }
            return "无法关闭：每侧至少保留 1 个标签"
        default:
            return "用法：tab new | tab close"
        }
    }
}
