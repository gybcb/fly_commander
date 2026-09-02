import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// 常驻窗口（搜索/SFTP/SMB/主题）随语言切换即时重刷。
/// 这四个 VC 的标签在 view-load 时一次性冻结；本测断言 refreshLocalizedText() 能把
/// 静态标签按当前语言重刷，且未加载视图的 VC/窗口刷新不会强行开窗（isViewLoaded 保持 false）。
/// 视图行为（真实弹窗）仍由 UI 测试覆盖，此处仅走 SPM 可测的 headless loadView + 刷新。
final class ResidentWindowRepaintTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    // MARK: - 视图树遍历（找静态标签，不依赖控件访问级别）

    /// 递归收集视图树内所有 NSTextField / NSButton（含 segment 所在容器由各自测单独处理）。
    private func allFields(_ root: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        func walk(_ v: NSView) {
            if let tf = v as? NSTextField { out.append(tf) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }
    private func allButtons(_ root: NSView) -> [NSButton] {
        var out: [NSButton] = []
        func walk(_ v: NSView) {
            if let b = v as? NSButton { out.append(b) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return out
    }
    private func containsField(_ root: NSView, _ text: String) -> Bool {
        allFields(root).contains { $0.stringValue == text }
    }
    private func containsButtonTitle(_ root: NSView, _ text: String) -> Bool {
        allButtons(root).contains { $0.title == text }
    }

    // MARK: - SearchViewController

    func testSearchVCRepaintsToChineseAndBack() {
        let vc = SearchViewController()
        _ = vc.view   // 强制 loadView（此时标签以 en 冻结）
        L10n.current = .zh
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.searchHint)), "搜索提示应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.startSearch)), "开始搜索按钮应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.cancel)), "取消按钮应为中文")

        L10n.current = .en
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.searchHint)), "搜索提示应回到英文")
        XCTAssertFalse(containsField(vc.view, "支持通配符 * 与 ?，递归搜索当前目录（跳过隐藏文件）"),
                       "旧中文串不应残留")
    }

    // MARK: - ThemeViewController

    func testThemeVCRepaintsToChineseAndBack() {
        let vc = ThemeViewController()
        _ = vc.view
        L10n.current = .zh
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.appearance)), "外观标签应为中文")
        XCTAssertTrue(containsField(vc.view, L10n.t(.accentColorHint)), "强调色标签应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.addRule)), "添加规则按钮应为中文")
        // segment 三段标签：外观选择器
        XCTAssertTrue(vc.segmentLabels().contains(L10n.t(.followSystem)), "跟随系统段应为中文")
        XCTAssertTrue(vc.segmentLabels().contains(L10n.t(.darkMode)), "深色段应为中文")

        L10n.current = .en
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.appearance)), "外观标签应回到英文")
        XCTAssertFalse(containsField(vc.view, "外观"), "旧中文串不应残留")
    }

    // MARK: - ConnectionViewController (SFTP)

    func testSFTPConnVCRepaintsToChineseAndBack() {
        let vc = ConnectionViewController()
        _ = vc.view
        L10n.current = .zh
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.fieldHost)), "主机标签应为中文")
        XCTAssertTrue(containsField(vc.view, L10n.t(.fieldPassphrase)), "密码短语标签应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.connect)), "连接按钮应为中文")
        // 单选/复选标题
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.fieldKeyFile)), "密钥文件单选应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.rememberPassword)), "记住密码复选应为中文")

        L10n.current = .en
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.fieldHost)), "主机标签应回到英文")
        XCTAssertFalse(containsField(vc.view, "主机"), "旧中文串不应残留")
    }

    // MARK: - SMBConnectionViewController

    func testSMBConnVCRepaintsToChineseAndBack() {
        let vc = SMBConnectionViewController()
        _ = vc.view
        L10n.current = .zh
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.fieldServer)), "服务器标签应为中文")
        XCTAssertTrue(containsField(vc.view, L10n.t(.fieldDomain)), "域标签应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.cancel)), "取消按钮应为中文")
        XCTAssertTrue(containsButtonTitle(vc.view, L10n.t(.rememberPassword)), "记住密码复选应为中文")

        L10n.current = .en
        vc.refreshLocalizedText()
        XCTAssertTrue(containsField(vc.view, L10n.t(.fieldServer)), "服务器标签应回到英文")
        XCTAssertFalse(containsField(vc.view, "服务器"), "旧中文串不应残留")
    }

    // MARK: - 窗口标题随 WindowController 重刷

    func testWindowControllersRepaintTitleAndContent() {
        let search = SearchWindowController()
        let sftp = ConnectionWindowController()
        let smb = SMBConnectionWindowController()
        let theme = ThemeWindowController()
        let checks: [(NSWindowController, L10nKey)] = [
            (search, .searchWindowTitle), (sftp, .sftpWindowTitle),
            (smb, .smbWindowTitle), (theme, .themeWindowTitle),
        ]
        // 强制加载内容 VC（此时标签以 en 冻结）。
        for (wc, _) in checks { _ = wc.window?.contentViewController?.view }

        L10n.current = .zh
        search.refreshLocalizedText()
        sftp.refreshLocalizedText()
        smb.refreshLocalizedText()
        theme.refreshLocalizedText()
        for (wc, key) in checks {
            XCTAssertEqual(wc.window?.title, L10n.t(key), "窗口标题应为中文（\(key.rawValue)）")
        }
        // 内容标签也应已切中文（抽查搜索窗提示）。
        XCTAssertTrue(containsField(search.window!.contentViewController!.view, L10n.t(.searchHint)))

        L10n.current = .en
        search.refreshLocalizedText()
        sftp.refreshLocalizedText()
        smb.refreshLocalizedText()
        theme.refreshLocalizedText()
        for (wc, key) in checks {
            XCTAssertEqual(wc.window?.title, L10n.t(key), "窗口标题应回到英文（\(key.rawValue)）")
        }
    }

    // MARK: - 未加载视图：刷新不强开视图
    // 注意：Swift extension 方法静态派生，故这些测用具体类型调用真实的 VC/WC 刷新，
    // 而非 [NSViewController]/[NSWindowController] 数组（会误命中基类实现）。

    func testRefreshOnUnloadedVCsDoesNotForceLoad() {
        let search = SearchViewController()
        let sftp = ConnectionViewController()
        let smb = SMBConnectionViewController()
        let theme = ThemeViewController()
        for vc in [search, sftp, smb, theme] as [NSViewController] {
            XCTAssertFalse(vc.isViewLoaded, "前置：视图尚未加载")
        }
        search.refreshLocalizedText()
        sftp.refreshLocalizedText()
        smb.refreshLocalizedText()
        theme.refreshLocalizedText()
        XCTAssertFalse(search.isViewLoaded)
        XCTAssertFalse(sftp.isViewLoaded)
        XCTAssertFalse(smb.isViewLoaded)
        XCTAssertFalse(theme.isViewLoaded)
    }

    func testWindowControllerRefreshDoesNotOpenWindow() {
        // 常驻窗口在 init 里把 VC 塞进 window.contentViewController → AppKit 即刻 loadView，
        // 故 WC 层不存在"内容 VC 未加载"这一状态（真实 init 不可达）。isViewLoaded 守卫的
        // 价值在 VC 层（裸 VC 刷新，见 testRefreshOnUnloadedVCsDoesNotForceLoad）。
        // WC 层真正要保证的是：语言重刷绝不把窗口弹到屏幕（不 showWindow/orderFront、不崩溃）。
        let search = SearchWindowController()
        let sftp = ConnectionWindowController()
        let smb = SMBConnectionWindowController()
        let theme = ThemeWindowController()
        L10n.current = .zh
        for wc in [search, sftp, smb, theme] {
            XCTAssertFalse(wc.window?.isVisible ?? true, "刷新前窗口本未显示")
        }
        search.refreshLocalizedText()
        sftp.refreshLocalizedText()
        smb.refreshLocalizedText()
        theme.refreshLocalizedText()
        for wc in [search, sftp, smb, theme] {
            XCTAssertFalse(wc.window?.isVisible ?? true, "语言重刷不应把窗口显示到屏幕")
        }
    }
}

/// ThemeViewController 的 segment 三段标签回读（外观选择器无独立可访问属性，用测试扩展读取）。
extension ThemeViewController {
    fileprivate func segmentLabels() -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let seg = v as? NSSegmentedControl {
                for i in 0..<seg.segmentCount { out.append(seg.label(forSegment: i) ?? "") }
            }
            v.subviews.forEach(walk)
        }
        if isViewLoaded { walk(view) }
        return out
    }
}
