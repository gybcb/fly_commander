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
        XCTAssertEqual(L10n.t(.showNextPrevTab), "显示下一/上一个窗口标签页")
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
    func testOnChangeFiresOnSwitch() {
        var fired = 0
        let token = L10n.observe { fired += 1 }
        L10n.current = .zh
        L10n.current = .en
        L10n.unobserve(token)
        XCTAssertEqual(fired, 2)
    }
}
