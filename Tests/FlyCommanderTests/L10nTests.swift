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
        XCTAssertEqual(L10n.t(.unrecoverable), "Cannot be undone")
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
    func testOnChangeFiresOnSwitch() {
        var fired = 0
        let token = L10n.observe { fired += 1 }
        L10n.current = .zh
        L10n.current = .en
        L10n.unobserve(token)
        XCTAssertEqual(fired, 2)
    }
}
