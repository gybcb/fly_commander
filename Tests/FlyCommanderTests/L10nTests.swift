import XCTest
@testable import FlyCommander
@testable import TCCore

final class L10nTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    func testDefaultIsEnglishWhenNoPreference() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        XCTAssertEqual(L10n.currentResolvedForTest, .en)
    }
    func testInterpolatedLookupEnglish() {
        XCTAssertEqual(L10n.t(.entered, "sftp://h:22/x"), "Entered sftp://h:22/x")
    }
    func testZhSwitchAndBack() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.entered, "/tmp"), "已进入 /tmp")
        L10n.current = .en
        XCTAssertEqual(L10n.t(.entered, "/tmp"), "Entered /tmp")
    }
    func testMissingKeyFallsBackEnglishNotRawKey() {
        L10n.current = .zh
        // testFallbackProbe 只在 en 表：zh 下必须落英文表值，而非 zh 缺失导致的 key.rawValue
        XCTAssertEqual(L10n.t(.testFallbackProbe), "__PROBE_EN__")
    }
    func testMenuToolbarKeysEnglish() {
        XCTAssertEqual(L10n.t(.newDirectory), "New Directory")
        XCTAssertEqual(L10n.t(.menuFile), "File")
        XCTAssertEqual(L10n.t(.rename), "Rename")
        XCTAssertEqual(L10n.t(.sftpConnect), "SFTP Connect…")
        XCTAssertEqual(L10n.t(.toolbarCopy), "Copy")
        XCTAssertEqual(L10n.t(.preview), "Preview")
        XCTAssertEqual(L10n.t(.editItem), "Edit")
        XCTAssertEqual(L10n.t(.menuEdit), "Edit")
    }
    func testMenuToolbarKeysChinese() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.newDirectory), "新建目录")
        XCTAssertEqual(L10n.t(.menuFile), "文件")
        XCTAssertEqual(L10n.t(.moveToTrash), "移到废纸篓")
        XCTAssertEqual(L10n.t(.themeEllipsis), "主题…")
    }
    func testDialogColumnKeysEnglish() {
        XCTAssertEqual(L10n.t(.conflictQuestion, "x"), "“x” already exists. How to handle?")
        XCTAssertEqual(L10n.t(.selectedCount, "3"), "3 selected")
        XCTAssertEqual(L10n.t(.colName), "Name")
        XCTAssertEqual(L10n.t(.colSize), "Size")
        XCTAssertEqual(L10n.t(.colDate), "Date Modified")
        XCTAssertEqual(L10n.t(.renameTitle), "Rename")
        XCTAssertEqual(L10n.t(.newDirTitle), "New Folder")
        XCTAssertEqual(L10n.t(.okBtn), "OK")
        XCTAssertEqual(L10n.t(.createBtn), "Create")
        XCTAssertEqual(L10n.t(.cancelBtn), "Cancel")
        XCTAssertEqual(L10n.t(.conflictTitle), "Item Already Exists")
        XCTAssertEqual(L10n.t(.overwrite), "Overwrite")
        XCTAssertEqual(L10n.t(.skip), "Skip")
        XCTAssertEqual(L10n.t(.overwriteAll), "Overwrite All")
        XCTAssertEqual(L10n.t(.skipAll), "Skip All")
        XCTAssertEqual(L10n.t(.trashConfirm, "5"), "Move 5 item(s) to Trash?")
        XCTAssertEqual(L10n.t(.deleteWord), "Delete")
        XCTAssertEqual(L10n.t(.remoteDeleteConfirm, "2"), "Delete 2 item(s) from the server?")
        XCTAssertEqual(L10n.t(.remoteNoTrash), "Remote has no Trash; deletion is permanent.")
        XCTAssertEqual(L10n.t(.cannotOpenFile), "Cannot open file")
        XCTAssertEqual(L10n.t(.closeTabTip), "Close Tab")
        XCTAssertEqual(L10n.t(.newTabTip), "New Tab")
        XCTAssertEqual(L10n.t(.statusErrorPrefix), "Error: ")
    }
    func testDialogColumnKeysChinese() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.conflictQuestion, "x"), "“x” 已存在，如何处理？")
        XCTAssertEqual(L10n.t(.selectedCount, "3"), "已选 3 项")
        XCTAssertEqual(L10n.t(.colName), "名称")
        XCTAssertEqual(L10n.t(.colSize), "大小")
        XCTAssertEqual(L10n.t(.colDate), "修改日期")
        XCTAssertEqual(L10n.t(.newDirTitle), "新建目录")
        XCTAssertEqual(L10n.t(.conflictTitle), "目标已存在")
        XCTAssertEqual(L10n.t(.trashConfirm, "5"), "删除 5 个文件到废纸篓？")
        XCTAssertEqual(L10n.t(.remoteDeleteConfirm, "2"), "从服务器删除 2 个文件？")
        XCTAssertEqual(L10n.t(.remoteNoTrash), "远端没有废纸篓，删除后无法恢复。")
        XCTAssertEqual(L10n.t(.cannotOpenFile), "无法打开文件")
        XCTAssertEqual(L10n.t(.statusErrorPrefix), "错误：")
    }
    func testSearchPreviewKeysEnglish() {
        XCTAssertEqual(L10n.t(.searchSummary, "2", "5"), "2 results, checked 5 items")
        XCTAssertEqual(L10n.t(.startSearch), "Search")
        XCTAssertEqual(L10n.t(.searchRootLabel, "/tmp"), "Search in /tmp")
        XCTAssertEqual(L10n.t(.searching), "Searching…")
        XCTAssertEqual(L10n.t(.searchingChecked, "10"), "Searching… checked 10 items")
        XCTAssertEqual(L10n.t(.searchStopped, "3"), "Stopped (3 results)")
        XCTAssertEqual(L10n.t(.searchNone, "7"), "No matches (checked 7 items)")
        XCTAssertEqual(L10n.t(.stopping), "Stopping…")
        XCTAssertEqual(L10n.t(.stop), "Stop")
        XCTAssertEqual(L10n.t(.newSearch), "New Search")
        XCTAssertEqual(L10n.t(.colFile), "File")
        XCTAssertEqual(L10n.t(.openWithDefault), "Open with Default App")
        XCTAssertEqual(L10n.t(.previewTruncBanner, "512 KB"), "Showing only first 512 KB")
        XCTAssertEqual(L10n.t(.previewOfFileTotal, "1.5 MB"), " (file total 1.5 MB)")
        XCTAssertEqual(L10n.t(.previewLongLineTrunc, "32 KB"), ", lines over 32 KB truncated")
        XCTAssertEqual(L10n.t(.lineTruncatedMark), " …(line truncated)")
        XCTAssertEqual(L10n.t(.cannotReadImage, "a.png"), "Cannot read image: a.png")
        XCTAssertEqual(L10n.t(.cannotPreview), "Cannot preview this file")
        XCTAssertEqual(L10n.t(.previewWindowTitlePlain), "FlyCommander Preview")
        XCTAssertEqual(L10n.t(.previewWindowTitle, "x.txt"), "FlyCommander Preview — x.txt")
    }
    func testSearchPreviewKeysChinese() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.searchSummary, "2", "5"), "共 2 个结果，已检查 5 项")
        XCTAssertEqual(L10n.t(.startSearch), "开始搜索")
        XCTAssertEqual(L10n.t(.searchRootLabel, "/tmp"), "在 /tmp 中搜索")
        XCTAssertEqual(L10n.t(.searchHint), "支持通配符 * 与 ?，递归搜索当前目录（跳过隐藏文件）")
        XCTAssertEqual(L10n.t(.searching), "搜索中…")
        XCTAssertEqual(L10n.t(.searchingChecked, "10"), "搜索中… 已检查 10 项")
        XCTAssertEqual(L10n.t(.searchStopped, "3"), "已停止（3 个结果）")
        XCTAssertEqual(L10n.t(.searchNone, "7"), "未找到匹配项（已检查 7 项）")
        XCTAssertEqual(L10n.t(.stopping), "正在停止…")
        XCTAssertEqual(L10n.t(.stop), "停止")
        XCTAssertEqual(L10n.t(.newSearch), "新搜索")
        XCTAssertEqual(L10n.t(.colFile), "文件")
        XCTAssertEqual(L10n.t(.openWithDefault), "用默认应用打开")
        XCTAssertEqual(L10n.t(.previewTruncBanner, "512 KB"), "仅显示前 512 KB")
        XCTAssertEqual(L10n.t(.previewOfFileTotal, "1.5 MB"), "（文件共 1.5 MB）")
        XCTAssertEqual(L10n.t(.previewLongLineTrunc, "32 KB"), "，超 32 KB 的长行已截断")
        XCTAssertEqual(L10n.t(.lineTruncatedMark), " …（行已截断）")
        XCTAssertEqual(L10n.t(.cannotReadImage, "a.png"), "无法读取图片：a.png")
        XCTAssertEqual(L10n.t(.cannotPreview), "无法预览此文件")
        XCTAssertEqual(L10n.t(.previewWindowTitlePlain), "FlyCommander 查看")
        XCTAssertEqual(L10n.t(.previewWindowTitle, "x.txt"), "FlyCommander 查看 — x.txt")
    }
    func testThemeCommandConnectionKeysEnglish() {
        XCTAssertEqual(L10n.t(.followSystem), "Follow System")
        XCTAssertEqual(L10n.t(.commandBarPrompt), "Command:")
        XCTAssertEqual(L10n.t(.appearance), "Appearance")
        XCTAssertEqual(L10n.t(.lightMode), "Light")
        XCTAssertEqual(L10n.t(.darkMode), "Dark")
        XCTAssertEqual(L10n.t(.accentColorHint), "Accent (marked-row background / active-pane border)")
        XCTAssertEqual(L10n.t(.fileColorHint), "File-type colors (extensions comma-separated; press Return to apply)")
        XCTAssertEqual(L10n.t(.addRule), "Add Rule")
        XCTAssertEqual(L10n.t(.restoreDefaults), "Restore Defaults")
        XCTAssertEqual(L10n.t(.commandBarPlaceholder), "Enter command (ls / cd / mkdir / copy / move / del / sftp / help)")
        XCTAssertEqual(L10n.t(.fieldPassword), "Password")
        XCTAssertEqual(L10n.t(.fieldPassphrase), "Passphrase")
        XCTAssertEqual(L10n.t(.fieldKeyFile), "Key File")
        XCTAssertEqual(L10n.t(.rememberPassword), "Remember Password")
        XCTAssertEqual(L10n.t(.fieldHost), "Host")
        XCTAssertEqual(L10n.t(.fieldPort), "Port")
        XCTAssertEqual(L10n.t(.fieldUser), "User")
        XCTAssertEqual(L10n.t(.fieldKey), "Key")
        XCTAssertEqual(L10n.t(.chooseWord), "Choose")
        XCTAssertEqual(L10n.t(.fillHost), "Please enter host")
        XCTAssertEqual(L10n.t(.invalidPort), "Invalid port")
        XCTAssertEqual(L10n.t(.chooseKeyFile), "Please choose a key file")
        XCTAssertEqual(L10n.t(.connecting), "Connecting…")
        XCTAssertEqual(L10n.t(.fieldServer), "Server")
        XCTAssertEqual(L10n.t(.fieldShare), "Share")
        XCTAssertEqual(L10n.t(.fieldDomain), "Domain")
        XCTAssertEqual(L10n.t(.fillServerShare), "Please enter server and share")
        XCTAssertEqual(L10n.t(.connectFailedPrefix), "Connect failed: ")
    }
    func testThemeCommandConnectionKeysChinese() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.followSystem), "跟随系统")
        XCTAssertEqual(L10n.t(.commandBarPrompt), "命令:")
        XCTAssertEqual(L10n.t(.appearance), "外观")
        XCTAssertEqual(L10n.t(.lightMode), "浅色")
        XCTAssertEqual(L10n.t(.darkMode), "深色")
        XCTAssertEqual(L10n.t(.accentColorHint), "强调色（标记行底色 / 活动窗格边框）")
        XCTAssertEqual(L10n.t(.fileColorHint), "文件类型配色（扩展名逗号分隔；编辑后按回车生效）")
        XCTAssertEqual(L10n.t(.addRule), "添加规则")
        XCTAssertEqual(L10n.t(.restoreDefaults), "恢复默认")
        XCTAssertEqual(L10n.t(.commandBarPlaceholder), "输入命令（ls / cd / mkdir / copy / move / del / sftp / help）")
        XCTAssertEqual(L10n.t(.fieldPassword), "密码")
        XCTAssertEqual(L10n.t(.fieldPassphrase), "密码短语")
        XCTAssertEqual(L10n.t(.fieldKeyFile), "密钥文件")
        XCTAssertEqual(L10n.t(.rememberPassword), "记住密码")
        XCTAssertEqual(L10n.t(.fieldHost), "主机")
        XCTAssertEqual(L10n.t(.fieldPort), "端口")
        XCTAssertEqual(L10n.t(.fieldUser), "用户")
        XCTAssertEqual(L10n.t(.fieldKey), "密钥")
        XCTAssertEqual(L10n.t(.chooseWord), "选择")
        XCTAssertEqual(L10n.t(.fillHost), "请填写主机")
        XCTAssertEqual(L10n.t(.invalidPort), "端口无效")
        XCTAssertEqual(L10n.t(.chooseKeyFile), "请选择密钥文件")
        XCTAssertEqual(L10n.t(.connecting), "连接中…")
        XCTAssertEqual(L10n.t(.fieldServer), "服务器")
        XCTAssertEqual(L10n.t(.fieldShare), "共享")
        XCTAssertEqual(L10n.t(.fieldDomain), "域")
        XCTAssertEqual(L10n.t(.fillServerShare), "请填写服务器与共享")
        XCTAssertEqual(L10n.t(.connectFailedPrefix), "连接失败：")
    }
    func testWindowTitleKeysEnglish() {
        XCTAssertEqual(L10n.t(.themeWindowTitle), "Theme")
        XCTAssertEqual(L10n.t(.sftpWindowTitle), "SFTP Connection")
        XCTAssertEqual(L10n.t(.smbWindowTitle), "SMB Connection")
        XCTAssertEqual(L10n.t(.searchWindowTitle), "Find Files")
    }
    func testWindowTitleKeysChinese() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.themeWindowTitle), "主题")
        XCTAssertEqual(L10n.t(.sftpWindowTitle), "SFTP 连接")
        XCTAssertEqual(L10n.t(.smbWindowTitle), "SMB 连接")
        XCTAssertEqual(L10n.t(.searchWindowTitle), "搜索文件")
    }
    // MARK: - 错误模板键（err*）英文

    func testErrorKeysEnglish() {
        XCTAssertEqual(L10n.t(.errNotFound, args: ["/a"]), "Not found: /a")
        XCTAssertEqual(L10n.t(.errPermissionDenied, args: ["/a"]), "Permission denied: /a")
        XCTAssertEqual(L10n.t(.errBusy, args: ["/x"]), "Busy: /x")
        XCTAssertEqual(L10n.t(.errInvalidPath, args: ["a/b"]), "Invalid path: a/b")
        XCTAssertEqual(L10n.t(.errCancelled, args: []), "Cancelled")
        XCTAssertEqual(L10n.t(.errAlreadyExists, args: ["a.txt"]), "Already exists: a.txt")
        XCTAssertEqual(L10n.t(.errAlreadyExistsBare, args: []), "Target already exists")
        XCTAssertEqual(L10n.t(.errDirExists, args: ["nd"]), "Directory already exists: nd")
        XCTAssertEqual(L10n.t(.errCrossSourceDir, args: ["sub"]),
                       "Cross-source directory transfer unsupported: sub")
        XCTAssertEqual(L10n.t(.errNoSpace, args: []), "No space left on device")
        XCTAssertEqual(L10n.t(.errSFTPNotExecuted, args: []), "SFTP operation did not execute")
        XCTAssertEqual(L10n.t(.errSMBMountFailed, args: ["7", "boom"]), "SMB mount failed (exit 7): boom")
        XCTAssertEqual(L10n.t(.errPutBackFailed, args: ["3", "nope"]), "Put-back mount failed (exit 3): nope")
        XCTAssertEqual(L10n.t(.errPathOutsideShare, args: ["/other"]), "Path outside share: /other")
        XCTAssertEqual(L10n.t(.errPathEscaped, args: ["/downloads/../../etc"]),
                       "Path escaped the mount point: /downloads/../../etc")
        XCTAssertEqual(
            L10n.t(.errMountPointHint, args: ["/Volumes/FlyCommander"]),
            "Cannot create mount point /Volumes/FlyCommander "
            + "(/Volumes not writable for current user). Run this once in Terminal:\n"
            + "sudo mkdir -p /Volumes/FlyCommander && sudo chown \"$(whoami)\" /Volumes/FlyCommander")
        // R-C1 裁决：errUnknown 模板是**裸 {0}**（状态栏前缀由 statusErrorPrefix 给，防双前缀）。
        XCTAssertEqual(L10n.t(.errUnknown, args: ["File exists"]), "File exists")
    }
    func testErrorKeysChinese() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.errNotFound, args: ["/a"]), "找不到：/a")
        XCTAssertEqual(L10n.t(.errPermissionDenied, args: ["/a"]), "没有权限访问：/a")
        XCTAssertEqual(L10n.t(.errBusy, args: ["/x"]), "忙碌/被占用：/x")
        XCTAssertEqual(L10n.t(.errInvalidPath, args: ["a/b"]), "无效路径：a/b")
        XCTAssertEqual(L10n.t(.errCancelled, args: []), "已取消")
        XCTAssertEqual(L10n.t(.errAlreadyExists, args: ["a.txt"]), "已存在同名：a.txt")
        XCTAssertEqual(L10n.t(.errAlreadyExistsBare, args: []), "目标已存在同名文件")
        XCTAssertEqual(L10n.t(.errDirExists, args: ["nd"]), "目录已存在：nd")
        XCTAssertEqual(L10n.t(.errCrossSourceDir, args: ["sub"]), "跨源传输暂不支持目录：sub")
        XCTAssertEqual(L10n.t(.errNoSpace, args: []), "磁盘空间不足")
        XCTAssertEqual(L10n.t(.errSFTPNotExecuted, args: []), "SFTP 操作未执行")
        XCTAssertEqual(L10n.t(.errSMBMountFailed, args: ["7", "boom"]), "SMB 挂载失败（exit 7）：boom")
        XCTAssertEqual(L10n.t(.errPutBackFailed, args: ["3", "nope"]), "挂回原处失败（exit 3）：nope")
        XCTAssertEqual(L10n.t(.errPathOutsideShare, args: ["/other"]), "路径不在共享内：/other")
        XCTAssertEqual(L10n.t(.errPathEscaped, args: ["/downloads/../../etc"]),
                       "路径逃逸挂载点：/downloads/../../etc")
        XCTAssertEqual(
            L10n.t(.errMountPointHint, args: ["/Volumes/FlyCommander"]),
            "无法创建挂载点 /Volumes/FlyCommander（/Volumes 对当前用户不可写）。请先在终端执行一次：\n"
            + "sudo mkdir -p /Volumes/FlyCommander && sudo chown \"$(whoami)\" /Volumes/FlyCommander")
        // R-C1：zh 侧同样是裸 {0}（"错误：" 前缀归 statusErrorPrefix）。
        XCTAssertEqual(L10n.t(.errUnknown, args: ["File exists"]), "File exists")
    }

    // MARK: - 边界翻译器 tcErrorDisplay

    func testTCErrorDisplayEnglish() {
        XCTAssertEqual(tcErrorDisplay(.notFound("/a")), "Not found: /a")
        XCTAssertEqual(tcErrorDisplay(.cancelled), "Cancelled")
        XCTAssertEqual(tcErrorDisplay(.noSpace), "No space left on device")
        XCTAssertEqual(tcErrorDisplay(.alreadyExists("a.txt")), "Already exists: a.txt")
        XCTAssertEqual(tcErrorDisplay(.alreadyExists(nil)), "Target already exists")
        XCTAssertEqual(tcErrorDisplay(.smbMountFailed(code: 7, diag: "boom")),
                       "SMB mount failed (exit 7): boom")
        XCTAssertEqual(tcErrorDisplay(.pathOutsideShare("/other")), "Path outside share: /other")
        XCTAssertEqual(tcErrorDisplay(.pathEscaped("/downloads/../../etc")),
                       "Path escaped the mount point: /downloads/../../etc")
        XCTAssertEqual(
            tcErrorDisplay(.mountPointNotWritable(root: "/Volumes/FlyCommander")),
            "Cannot create mount point /Volumes/FlyCommander "
            + "(/Volumes not writable for current user). Run this once in Terminal:\n"
            + "sudo mkdir -p /Volumes/FlyCommander && sudo chown \"$(whoami)\" /Volumes/FlyCommander")
        // R-C1：.unknown 走**裸 {0}** 模板——前缀由外层（statusErrorPrefix 等）负责，边界不叠字。
        XCTAssertEqual(tcErrorDisplay(.unknown("File exists")), "File exists")
    }
    func testTCErrorDisplayChinese() {
        L10n.current = .zh
        XCTAssertEqual(tcErrorDisplay(.notFound("/a")), "找不到：/a")
        XCTAssertEqual(tcErrorDisplay(.cancelled), "已取消")
        XCTAssertEqual(tcErrorDisplay(.noSpace), "磁盘空间不足")
        XCTAssertEqual(tcErrorDisplay(.alreadyExists("a.txt")), "已存在同名：a.txt")
        XCTAssertEqual(tcErrorDisplay(.alreadyExists(nil)), "目标已存在同名文件")
        XCTAssertEqual(tcErrorDisplay(.smbMountFailed(code: 7, diag: "boom")),
                       "SMB 挂载失败（exit 7）：boom")
        XCTAssertEqual(tcErrorDisplay(.pathOutsideShare("/other")), "路径不在共享内：/other")
        XCTAssertEqual(tcErrorDisplay(.pathEscaped("/downloads/../../etc")),
                       "路径逃逸挂载点：/downloads/../../etc")
        // zh 多行模板逐字含 \n + 命令行（{0} 出现 3 次全替换）。
        XCTAssertEqual(
            tcErrorDisplay(.mountPointNotWritable(root: "/Volumes/FlyCommander")),
            "无法创建挂载点 /Volumes/FlyCommander（/Volumes 对当前用户不可写）。请先在终端执行一次：\n"
            + "sudo mkdir -p /Volumes/FlyCommander && sudo chown \"$(whoami)\" /Volumes/FlyCommander")
        // R-C1：zh 边界同为裸 payload（前缀归 statusErrorPrefix）。
        XCTAssertEqual(tcErrorDisplay(.unknown("File exists")), "File exists")
    }

    func testOnChangeFiresOnSwitch() {
        var fired = 0
        let token = L10n.observe { fired += 1 }
        L10n.current = .zh
        L10n.current = .en
        L10n.unobserve(token)
        XCTAssertEqual(fired, 2)
    }

    /// 覆盖性守卫：每个 L10nKey 都必须在 en 表有值；除故意只进 en 表的
    /// testFallbackProbe（专测 zh→en 兜底，见上）外，都必须在 zh 表也有值。
    /// 防的是"加了 enum case 却漏补表文案"这类静默 bug（t() 会退回 rawValue）。
    func testEveryKeyTabledInEnglishAndChinese() {
        let enOnly: Set<L10nKey> = [.testFallbackProbe]
        for key in L10nKey.allCases {
            XCTAssertNotNil(L10nTable.en[key], "en 表缺少 key：\(key.rawValue)")
            if !enOnly.contains(key) {
                XCTAssertNotNil(L10nTable.zh[key], "zh 表缺少 key：\(key.rawValue)")
            }
        }
        // 反向：表里不得有 allCases 之外的野键（枚举与表结构必须一致）。
        for key in L10nTable.en.keys { XCTAssertTrue(L10nKey.allCases.contains(key), "en 表有未定义 key：\(key.rawValue)") }
        for key in L10nTable.zh.keys { XCTAssertTrue(L10nKey.allCases.contains(key), "zh 表有未定义 key：\(key.rawValue)") }
    }
}
