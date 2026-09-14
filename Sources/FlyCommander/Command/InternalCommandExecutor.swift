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
    /// ftp 命令入口（弹连接窗并预选 FTP；host/port 可预填，nil=不预填）。
    var onConnectFTP: ((_ host: String?, _ port: UInt16?) -> Void)?
    /// theme 命令入口（弹主题窗）。
    var onOpenTheme: (() -> Void)?
    /// update 命令入口（手动检查更新：弹更新窗或「已是最新」提示，全在 flow 侧决策）。
    var onCheckUpdate: (() -> Void)?
    /// tab new 命令入口（app 侧建标签）。
    var onNewTab: (() -> Void)?
    /// tab close 命令入口（app 侧关活动标签）；返回 false=最后一个标签无法关。
    var onCloseTab: (() -> Bool)?

    init(workspace: Workspace, engine: OperationEngine) {
        self.workspace = workspace
        self.engine = engine
    }

    // MARK: - 命令清单

    /// helpText 按 key 拆条拼装（zh 逐字搬现码；en 版不逐列对齐，保持可读即可）。
    static var helpText: String {
        [
            L10n.t(.helpHeader),
            L10n.t(.helpCd),
            L10n.t(.helpLs),
            L10n.t(.helpMkdir),
            L10n.t(.helpCopy),
            L10n.t(.helpMove),
            L10n.t(.helpDel),
            L10n.t(.helpView),
            L10n.t(.helpEdit),
            L10n.t(.helpSftp),
            L10n.t(.helpSmb),
            L10n.t(.helpFtp),
            L10n.t(.helpTabNew),
            L10n.t(.helpTabClose),
            L10n.t(.helpTheme),
            L10n.t(.helpUpdate),
            L10n.t(.helpRefresh),
            L10n.t(.helpLang),
            L10n.t(.helpHelp),
        ].joined(separator: "\n")
    }

    // MARK: - 入口

    /// 执行一行命令，返回回显文本（nil = 无输出）。
    @discardableResult
    func execute(line: String) -> String? {
        let cmd: ParsedCommand
        do { cmd = try CommandLineParser.parse(line) }
        catch let e as CommandLineError {
            return e == .empty ? nil : L10n.t(.syntaxError)
        }
        catch { return L10n.t(.syntaxError) }

        switch cmd.name {
        case "cd": return doCd(cmd.args)
        case "ls": return doLs()
        case "mkdir": return doMkdir(cmd.args)
        case "copy": runTransfer(.copy); return L10n.t(.copyInitiated)
        case "move": runTransfer(.move); return L10n.t(.moveInitiated)
        case "del": return doDel(cmd.args)
        case "view": return doView()
        case "edit": return doEdit()
        case "sftp": return doSFTP(cmd.args)
        case "smb": return doSMB(cmd.args)
        case "ftp": return doFTP(cmd.args)
        case "tab": return doTab(cmd.args)
        case "theme": onOpenTheme?(); return L10n.t(.themeOpened)
        case "update": onCheckUpdate?(); return nil   // 反馈全在 flow 侧（弹窗/alert），命令栏不抢回显
        case "refresh":
            // 与 CommandRouter .refresh 同语义（executor 不持 router，就地内联 reloadPane
            // 两行）：远端 loadAsync 防网络卡主线程，load 缺省 preserveFocus:true 保焦点。
            let pane = workspace.activePane
            if pane.source.isRemote { pane.loadAsync() } else { pane.load() }
            return L10n.t(.refreshed)
        case "lang": return doLang(cmd.args)
        case "help": return Self.helpText
        default: return L10n.t(.unknownCommand, cmd.name)
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
                    return L10n.t(.remoteSftpOnly)
                }
            } else {
                if TCPath(raw).isRemote {
                    return L10n.t(.localCannotCdSftp)
                }
                target = raw.hasPrefix("/") ? TCPath(raw)
                    : TCPath((pane.path.url.path as NSString).appendingPathComponent(raw))
            }
        }
        if pane.source.isRemote {
            // navigate 的远端 stat 已异步化，path 不会同步变化，不能靠 path 判定成败；
            // 命令栏回显需要同步结果，这里自己 stat 校验一次（同步网络 RTT 与旧同步 navigate 同价）。
            guard (try? pane.source.stat(target))?.isDirectory == true else {
                return L10n.t(.cannotEnterNotDirectory, target.displayString())
            }
            pane.navigate(to: target)
            return L10n.t(.entered, target.displayString())
        }
        let before = pane.path
        pane.navigate(to: target)
        return pane.path == before ? L10n.t(.cannotEnterNotDirectory, target.displayString())
                                   : L10n.t(.entered, pane.path.displayString())
    }

    private func hostOf(_ path: TCPath) -> String {
        guard let host = path.url.host, let port = path.url.port else { return "" }
        return "\(host):\(port)"
    }

    private func doLs() -> String? {
        let pane = workspace.activePane
        if let err = pane.lastError {
            return L10n.t(.readFailed, tcErrorDisplay(err))
        }
        return L10n.t(.lsSummary, pane.path.displayString(), "\(pane.itemCount)")
    }

    private func doMkdir(_ args: [String]) -> String? {
        guard args.count == 1, !args[0].isEmpty else { return L10n.t(.mkdirUsage) }
        let pane = workspace.activePane
        let before = pane.path
        do {
            let dir = try engine.performMakeDirectory(args[0], in: before, source: pane.source)
            pane.load()
            return L10n.t(.mkdirDone, dir.displayString())
        } catch let e as TCError {
            return L10n.t(.mkdirFailed, tcErrorDisplay(e))
        } catch {
            return L10n.t(.mkdirFailed, error.localizedDescription)
        }
    }

    private func runTransfer(_ id: CommandID) {
        let pane = workspace.activePane
        guard !pane.operationTargets.isEmpty else {
            setStatus(L10n.t(.nothingToTransfer))
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
            // 筛选期只删**可见项**（决策 5）；不过滤时 visibleItemIDs 即全量，行为不变。
            let byID = pane.itemByID
            targets = pane.visibleItemIDs.compactMap { byID[$0] }
        } else {
            // 显式命名 del <id> 不按可见性过滤：用户逐字敲名是明确意图（已批准取舍）。
            let byID = pane.itemByID
            let found = args.compactMap { byID[$0] }
            if found.count != args.count {
                let missing = args.filter { byID[$0] == nil }
                return L10n.t(.notFoundItems, missing.joined(separator: " "))
            }
            targets = found
        }
        guard !targets.isEmpty else { return L10n.t(.nothingToDelete) }
        onDelete?(InternalDeleteRequest(pane: pane, targets: targets))
        return L10n.t(.deleteInitiated, "\(targets.count)")
    }

    private func doView() -> String? {
        guard let item = workspace.activePane.focusedItem else { return L10n.t(.noFocusedItem) }
        if item.isDirectory { return L10n.t(.dirNotPreviewable) }
        if workspace.activePane.source.isRemote {
            return L10n.t(.remoteNoPreview)
        }
        workspace.onCommandView?(item)
        return nil
    }

    private func doEdit() -> String? {
        guard let item = workspace.activePane.focusedItem else { return L10n.t(.noFocusedItem) }
        if item.isDirectory { return L10n.t(.dirNotEditable) }
        if workspace.activePane.source.isRemote {
            return L10n.t(.remoteNoEdit)
        }
        workspace.onCommandEdit?(item)
        return nil
    }

    /// `host[:port]` 解析（sftp/ftp 共用；port 非法→nil，不报错——沿用旧行为）。
    private static func parseHostPort(_ arg: String) -> (host: String, port: UInt16?) {
        let parts = arg.split(separator: ":", maxSplits: 1)
        return (String(parts[0]), parts.count == 2 ? UInt16(parts[1]) : nil)
    }

    private func doSFTP(_ args: [String]) -> String? {
        guard args.count <= 1 else { return L10n.t(.sftpUsage) }
        var host: String?, port: UInt16?
        if let arg = args.first, !arg.isEmpty {
            let parsed = Self.parseHostPort(arg)
            host = parsed.host
            port = parsed.port
        }
        onConnectSFTP?(host, port)
        return host != nil ? L10n.t(.sftpOpenedHost, host!) : L10n.t(.sftpOpened)
    }

    /// `ftp host[:port]`：打开统一连接窗并预选 FTP（协议层执行器由并行任务接线）。
    private func doFTP(_ args: [String]) -> String? {
        guard args.count <= 1 else { return L10n.t(.ftpUsage) }
        var host: String?, port: UInt16?
        if let arg = args.first, !arg.isEmpty {
            let parsed = Self.parseHostPort(arg)
            host = parsed.host
            port = parsed.port
        }
        onConnectFTP?(host, port)
        return host != nil ? L10n.t(.ftpOpenedHost, host!) : L10n.t(.ftpOpened)
    }

    private func doSMB(_ args: [String]) -> String? {
        guard args.count <= 2 else { return L10n.t(.smbUsage) }
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
        return server != nil ? L10n.t(.smbOpenedServer, server!) : L10n.t(.smbOpened)
    }

    private func doTab(_ args: [String]) -> String? {
        switch args.first?.lowercased() {
        case "new", nil:
            onNewTab?()
            return L10n.t(.tabCreated)
        case "close":
            if let closed = onCloseTab?(), closed { return L10n.t(.tabClosed) }
            return L10n.t(.tabCannotCloseLast)
        default:
            return L10n.t(.tabUsage)
        }
    }

    /// lang 命令：仅切 L10n.current（写入 UserDefaults + 广播 observe 已在 setter 内）。
    /// UI 全局重建不在此接线（Task 7）。
    /// 回显串在切换**之前**按当前语言构建（故 `lang zh` 从英文起返回 "Language set to Chinese"），
    /// 与 brief 固定值一致；再落 L10n.current。
    private func doLang(_ args: [String]) -> String? {
        guard let raw = args.first else {
            return L10n.t(.langUsageCurrent, L10n.t(currentLangNameKey))
        }
        switch raw.lowercased() {
        case "en":
            let msg = L10n.t(.langSet, L10n.t(.langEnglishName))
            L10n.current = .en
            return msg
        case "zh":
            let msg = L10n.t(.langSet, L10n.t(.langChineseName))
            L10n.current = .zh
            return msg
        default:
            return L10n.t(.langUnknown, raw)
        }
    }

    /// 当前语言对应"名称 key"（切中/英后名称本身仍用当前语言回显）。
    private var currentLangNameKey: L10nKey {
        L10n.current == .en ? .langEnglishName : .langChineseName
    }
}
