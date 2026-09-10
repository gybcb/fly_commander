import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T7b：InternalCommandExecutor 单测（fake 源 + 真实 FilePane/Workspace）。
/// 覆盖：cd 本地/远程（含拦截）、mkdir 远程、del 远程拦截语义（走 onDelete 钩子不直接删）、
/// ls/help/sftp 回显与参数。

private final class StubSource: FileSource {
    let sourceID: String
    var isRemote: Bool
    var supportsTransfer = true
    var table: [String: FileItem] = [:]
    var dirItems: [FileItem] = []
    var mkdirError: TCError?
    var listError: TCError?
    var lastErrorSim: TCError?

    init(id: String, remote: Bool) { sourceID = id; isRemote = remote }

    func item(_ path: String, dir: Bool = false) -> FileItem {
        FileItem(id: path, path: TCPath(path), name: (path as NSString).lastPathComponent,
                 isDirectory: dir, size: dir ? 0 : 1, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        if let e = listError { throw e }
        return dirItems
    }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? { table[path.pathString] }
    func copyItem(from: TCPath, to: TCPath) throws { table[to.pathString] = table[from.pathString] }
    func moveItem(from: TCPath, to: TCPath) throws { table[to.pathString] = table.removeValue(forKey: from.pathString) }
    func renameItem(at: TCPath, to: TCPath) throws { table[to.pathString] = table.removeValue(forKey: at.pathString) }
    func makeDirectory(at: TCPath) throws {
        if let e = mkdirError { throw e }
        table[at.pathString] = item(at.pathString, dir: true)
        dirItems.append(table[at.pathString]!)
    }
    func removeItem(at: TCPath) throws { table[at.pathString] = nil }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        var sent = false
        return { _ in if sent { return Data() }; sent = true; return Data() }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {}
}

private final class Harness {
    let workspace: Workspace
    let executor: InternalCommandExecutor
    var deleted: InternalDeleteRequest?
    var connect: (host: String?, port: UInt16?)?
    var smbConnect: (server: String?, share: String?, user: String?)?
    var transfers: [CommandID] = []
    var viewItem: FileItem?
    var editItem: FileItem?
    var themeOpened = 0
    var newTab = 0
    var closeTab = true

    init(local: StubSource, remote: StubSource, activeRemote: Bool) {
        let left = FilePane(id: .left, source: local, startPath: TCPath("/L"))
        let right = FilePane(id: .right, source: remote, startPath: TCPath("sftp://h:2222/R"))
        let ws = Workspace(left: left, right: right, active: activeRemote ? .right : .left)
        left.load()
        right.load()
        let exec = InternalCommandExecutor(workspace: ws, engine: OperationEngine())
        workspace = ws
        executor = exec
        exec.onDelete = { [weak self] r in self?.deleted = r }
        exec.onConnectSFTP = { [weak self] h, p in self?.connect = (h, p) }
        exec.onConnectSMB = { [weak self] s, sh, u in self?.smbConnect = (s, sh, u) }
        ws.onCommandTransfer = { [weak self] c in self?.transfers.append(c) }
        ws.onCommandView = { [weak self] i in self?.viewItem = i }
        ws.onCommandEdit = { [weak self] i in self?.editItem = i }
        exec.onOpenTheme = { [weak self] in self?.themeOpened += 1 }
        exec.onNewTab = { [weak self] in self?.newTab += 1 }
        exec.onCloseTab = { [weak self] in self?.closeTab ?? true }
    }

    /// 在本地源里放文件 a.txt/b.txt 并让活动窗格聚焦第一个。
    func seedLocal(_ names: [String]) {
        let src = workspace.activePane.source as! StubSource
        src.dirItems = names.map { src.item("/L/\($0)") }
        for n in names { src.table["/L/\(n)"] = src.item("/L/\(n)") }
        workspace.activePane.load()
        _ = workspace.activePane.revealItem(id: "/L/\(names[0])")
    }

    /// 在远程源里放文件并聚焦。
    func seedRemote(_ names: [String]) {
        let src = workspace.activePane.source as! StubSource
        src.dirItems = names.map { src.item("/R/\($0)") }
        for n in names { src.table["/R/\(n)"] = src.item("/R/\(n)") }
        workspace.activePane.load()
        _ = workspace.activePane.revealItem(id: "/R/\(names[0])")
    }
}

final class InternalCommandExecutorTests: XCTestCase {
    // L10n.current 是进程级静态；本文件默认英文断言，故 setUp/tearDown 复位为 .en，
    // 防 lang 测试切到 zh 后泄漏到其它断言。
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    // MARK: - ls / help

    func testLsEchoesItemCount() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "sftp://h:2222", remote: true), activeRemote: false)
        h.seedLocal(["a.txt", "b.txt"])
        let out = h.executor.execute(line: "ls")
        XCTAssertEqual(out, "/L: 2 items")
    }

    func testHelpListsCommands() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "help")
        for kw in ["cd", "ls", "mkdir", "copy", "move", "del", "view", "edit", "sftp", "smb", "tab", "theme", "lang", "help"] {
            XCTAssertTrue(out?.contains(kw) ?? false, "help 应含 \(kw)：\(out ?? "nil")")
        }
        XCTAssertTrue(out?.contains("refresh") ?? false, "help 应含 refresh（新命令须入帮助表）")
    }

    // MARK: - refresh（手动刷新命令栏路）

    /// 本地 `refresh`：重载源当前列表（外部改动现形）+ 回显 refreshed。
    /// 变异：case "refresh" 删掉 → 回显 unknownCommand 红；
    /// 分支体删重载行 → 回显正确但列表停留旧内容 → items 断言红。
    func testRefreshCommandReloadsLocalPaneAndEchoes() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        h.seedLocal(["a.txt", "b.txt"])
        let src = h.workspace.activePane.source as! StubSource
        src.dirItems = src.dirItems + [src.item("/L/new.txt")]   // 模拟外部新增

        let out = h.executor.execute(line: "refresh")
        XCTAssertEqual(out, L10n.t(.refreshed))
        XCTAssertEqual(Set(h.workspace.activePane.page?.items.map(\.name) ?? []),
                       ["a.txt", "b.txt", "new.txt"], "refresh 须见新列表")
    }

    /// 远端活动窗格 `refresh`：必须异步（execute 返回瞬间列表仍旧；回调后才新）。
    /// 变异：分支改成裸 `pane.load()` → execute 返回瞬间已见 new.txt → 中间断言红。
    func testRefreshCommandOnRemotePaneIsAsync() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "sftp://h:2222", remote: true), activeRemote: true)
        h.seedRemote(["old.txt"])
        let src = h.workspace.activePane.source as! StubSource
        src.dirItems = [src.item("/R/new.txt")]                  // 外部改远端列表

        let out = h.executor.execute(line: "refresh")
        XCTAssertEqual(out, L10n.t(.refreshed))
        XCTAssertEqual(h.workspace.activePane.page?.items.map(\.name), ["old.txt"],
                       "远端 refresh 不得同步阻塞——execute 返回瞬间仍旧内容")

        let done = expectation(description: "async refresh done")
        h.workspace.activePane.onReload = { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(h.workspace.activePane.page?.items.map(\.name), ["new.txt"])
    }

    // MARK: - lang（切换语言）

    func testLangSwitchesLanguage() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        // 从英文起：lang zh 回显用切换前的语言（英）构建 → "Language set to Chinese"，再落 zh。
        XCTAssertEqual(h.executor.execute(line: "lang zh"), "Language set to Chinese")
        XCTAssertEqual(L10n.current, .zh)
        // 切回 en：行为意图=状态回到 .en（回显串此时按切换前的 zh 表构建，不固定字面）。
        _ = h.executor.execute(line: "lang en")
        XCTAssertEqual(L10n.current, .en)
    }

    func testLangNoArgShowsCurrent() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        XCTAssertEqual(h.executor.execute(line: "lang"), "Language: English (usage: lang en | lang zh)")
        _ = h.executor.execute(line: "lang zh")
        XCTAssertEqual(h.executor.execute(line: "lang"), "当前语言：简体中文（用法：lang en | lang zh）")
        _ = h.executor.execute(line: "lang en")   // 复位，防泄漏（tearDown 亦兜底）
    }

    func testLangUnknown() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        XCTAssertEqual(h.executor.execute(line: "lang xx"), "Unknown language: xx (en / zh)")
        XCTAssertEqual(L10n.current, .en, "未知语言不得改状态")
    }

    func testUnknownCommand() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "frobnicate")
        XCTAssertEqual(out, "Unknown command: frobnicate (type help)")
    }

    // MARK: - cd 本地

    func testCdLocalRelative() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        local.table["/L/sub"] = local.item("/L/sub", dir: true)
        let out = h.executor.execute(line: "cd sub")
        XCTAssertEqual(out, "Entered /L/sub")
        XCTAssertEqual(h.workspace.activePane.path.pathString, "/L/sub")
    }

    func testCdLocalAbsolute() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        local.table["/tmp/x"] = local.item("/tmp/x", dir: true)
        let out = h.executor.execute(line: "cd /tmp/x")
        XCTAssertEqual(out, "Entered /tmp/x")
    }

    func testCdLocalRejectsSftpTarget() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        let out = h.executor.execute(line: "cd sftp://h:22/x")
        XCTAssertEqual(out, "Local pane cannot cd to sftp:// (use the sftp command first)")
    }

    // MARK: - cd 远程

    func testCdRemoteAcceptsSftpPath() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        remote.table["/R/deep"] = remote.item("/R/deep", dir: true)
        let out = h.executor.execute(line: "cd sftp://h:2222/R/deep")
        XCTAssertEqual(out, "Entered sftp://h:2222/R/deep")
    }

    func testCdRemoteRejectsLocalPath() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        let out = h.executor.execute(line: "cd /etc")
        XCTAssertEqual(out, "Remote pane accepts only sftp://host:port/path")
    }

    func testCdMissingDirReportsFailure() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        // 目标不在 table → stat nil → navigate 拒绝（路径不变）
        let out = h.executor.execute(line: "cd /L/nonexistent")
        XCTAssertEqual(out, "Cannot enter: /L/nonexistent (missing or not a directory)")
    }

    // MARK: - mkdir（远程）

    func testMkdirRemote() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        let out = h.executor.execute(line: "mkdir nd")
        XCTAssertEqual(out, "Created sftp://h:2222/R/nd")
        XCTAssertNotNil(remote.table["/R/nd"])
    }

    func testMkdirRemoteFailureSurfacesTCError() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        remote.mkdirError = TCError.permissionDenied("nope")
        let out = h.executor.execute(line: "mkdir nd")
        XCTAssertTrue(out?.hasPrefix("Create failed:") ?? false, "got: \(out ?? "nil")")
    }

    /// Plan B T3：显示点走 tcErrorDisplay（边界翻译），不是内部英文 message。
    /// en 下两脸同形，故必须在 zh 下断——回退到 `e.message` 就会红。
    func testMkdirFailureBodyIsLocalizedAtDisplayBoundary() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        remote.mkdirError = TCError.permissionDenied("nope")
        XCTAssertEqual(h.executor.execute(line: "mkdir nd"), "新建失败：没有权限访问：nope")
    }

    /// mkdir 撞同名目录 → 语义 case `.dirExists`，回显经边界翻译为 zh 现码。
    func testMkdirExistingDirectoryMessageIsLocalized() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        remote.table["/R/nd"] = remote.item("/R/nd", dir: true)   // 同名目录已存在
        XCTAssertEqual(h.executor.execute(line: "mkdir nd"), "新建失败：目录已存在：nd")
    }

    /// ls 在窗格有 lastError 时回显 readFailed，错误体同样走边界翻译。
    func testLsReadFailureBodyIsLocalized() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let local = StubSource(id: "local", remote: false)
        local.listError = TCError.permissionDenied("/L")
        let h = Harness(local: local, remote: StubSource(id: "s", remote: true), activeRemote: false)
        h.workspace.activePane.load()
        XCTAssertEqual(h.executor.execute(line: "ls"), "目录读取失败：没有权限访问：/L")
    }

    func testMkdirRequiresExactlyOneArg() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        XCTAssertEqual(h.executor.execute(line: "mkdir"), "Usage: mkdir NAME")
        XCTAssertEqual(h.executor.execute(line: "mkdir a b"), "Usage: mkdir NAME")
    }

    // MARK: - del（远程拦截语义：不直接删，走 onDelete 钩子）

    func testDelRemoteDelegatesToOnDeleteNotDirectRemove() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt", "b.txt"])
        // del * = 全部
        h.executor.execute(line: "del *")
        XCTAssertNotNil(h.deleted, "del 应走 onDelete 钩子（确认后删除）")
        XCTAssertEqual(h.deleted?.targets.map(\.name), ["a.txt", "b.txt"])
        // 文件此刻不应已被删（等待确认流）
        XCTAssertNotNil(remote.table["/R/a.txt"], "确认前不得真删")
    }

    func testDelRemoteMissingTargetReports() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        let out = h.executor.execute(line: "del nope.txt")
        XCTAssertEqual(out, "Not found: nope.txt (nothing here)")
        XCTAssertNil(h.deleted)
    }

    func testDelDefaultTargetsFocused() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt", "b.txt"])
        h.executor.execute(line: "del")
        XCTAssertEqual(h.deleted?.targets.map(\.name), ["a.txt"], "缺省=焦点项")
    }

    /// 筛选期 `del *` 只删**可见项**（决策 5）。
    /// 变异：把 `pane.visibleItemIDs` 改回 `pane.page?.items` → 被筛掉的 b.md 也被删，本用例红。
    func testDelStarTargetsOnlyVisibleWhenFiltering() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt", "b.md", "c.txt"])
        h.workspace.activePane.setFilter("txt")
        h.executor.execute(line: "del *")
        XCTAssertEqual(h.deleted?.targets.map(\.name), ["a.txt", "c.txt"],
                       "只删可见项；不过滤时 visibleItemIDs 即全量（既有用例覆盖）")
    }

    /// 显式 `del <id>` 不受筛选影响：逐字敲名是明确意图（已批准取舍）。
    /// 变异：给显式分支加可见门禁（改用 operationTargets 或 visibleItemIDs）→ 本用例红。
    func testDelExplicitIDIgnoresFilter() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt", "b.md", "c.txt"])
        h.workspace.activePane.setFilter("txt")     // b.md 被筛掉
        let out = h.executor.execute(line: "del /L/b.md")
        XCTAssertEqual(h.deleted?.targets.map(\.name), ["b.md"])
        XCTAssertEqual(out, "Delete started for 1 item(s) (awaiting confirm)")
    }

    // MARK: - view / edit 远程降级

    func testViewRemoteDowngrades() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        let out = h.executor.execute(line: "view")
        XCTAssertEqual(out, "Remote preview unsupported, download first")
        XCTAssertNil(h.viewItem)
    }

    func testViewLocalDelegates() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt"])
        h.executor.execute(line: "view")
        XCTAssertEqual(h.viewItem?.name, "a.txt")
    }

    // MARK: - sftp 参数

    func testSFTPNoArg() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "sftp")
        XCTAssertNil(h.connect?.0)
        XCTAssertNil(h.connect?.1)
        XCTAssertEqual(out, "SFTP connection window opened")
    }

    func testSFTPWithHostPort() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "sftp 10.0.0.5:2222")
        XCTAssertEqual(h.connect?.0, "10.0.0.5")
        XCTAssertEqual(h.connect?.1, 2222)
    }

    func testSFTPWithHostOnly() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "sftp example.com")
        XCTAssertEqual(h.connect?.0, "example.com")
        XCTAssertNil(h.connect?.1)
    }

    // MARK: - smb 参数

    func testSMBCommandParsesServerShareUser() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "smb truenas/downloads shaogaoyang")
        XCTAssertEqual(h.smbConnect?.0, "truenas")
        XCTAssertEqual(h.smbConnect?.1, "downloads")
        XCTAssertEqual(h.smbConnect?.2, "shaogaoyang")
    }

    func testSMBCommandBareServer() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "smb truenas")
        XCTAssertEqual(h.smbConnect?.0, "truenas")
        XCTAssertNil(h.smbConnect?.1)
        XCTAssertNil(h.smbConnect?.2)
    }

    /// 回归：首参全为分隔符时 split 返回 []，不得越界崩溃，应按空参开窗。
    func testSMBCommandSeparatorOnlyOpensBare() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "smb /")
        XCTAssertNil(h.smbConnect?.0)
        XCTAssertNil(h.smbConnect?.1)
        XCTAssertNil(h.smbConnect?.2)
    }

    func testSMBCommandTooManyArgs() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "smb a b c")
        XCTAssertNil(h.smbConnect, "参数过多时不应触发连接钩子")
        XCTAssertEqual(out, "Usage: smb [server[/share]] [user]")
    }

    // MARK: - copy/move 走 workspace 钩子

    func testCopyDelegatesToWorkspaceHook() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt"])
        _ = h.executor.execute(line: "copy")
        XCTAssertEqual(h.transfers, [.copy])
    }

    func testMoveDelegatesToWorkspaceHook() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt"])
        _ = h.executor.execute(line: "move")
        XCTAssertEqual(h.transfers, [.move])
    }

    func testThemeCommandOpensWindow() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "theme")
        XCTAssertEqual(h.themeOpened, 1)
        XCTAssertEqual(out, "Theme window opened")
    }

    // MARK: - tab（多标签入口）

    func testTabNewOpensTab() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "tab new")
        XCTAssertEqual(h.newTab, 1, "tab new 应触发一次 onNewTab")
        XCTAssertEqual(out, "Tab created")
    }

    func testTabBareDefaultsToNew() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "tab")
        XCTAssertEqual(h.newTab, 1, "裸 tab 默认新建")
    }

    func testTabCloseSucceeds() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        h.closeTab = true
        let out = h.executor.execute(line: "tab close")
        XCTAssertEqual(h.newTab, 0, "close 不新建")
        XCTAssertEqual(out, "Tab closed")
    }

    func testTabCloseRefusedOnLastTab() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        h.closeTab = false
        let out = h.executor.execute(line: "tab close")
        XCTAssertEqual(h.newTab, 0)
        XCTAssertEqual(out, "Cannot close: keep at least 1 tab per side")
    }

    func testTabUnknownArgUsage() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "tab foo")
        XCTAssertEqual(out, "Usage: tab new | tab close")
    }
}
