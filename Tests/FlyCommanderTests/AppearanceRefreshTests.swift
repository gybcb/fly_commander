import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// 系统明暗切换后颜色重解回归（viewDidChangeEffectiveAppearance 逐视图钩子）。
///
/// 范式：真 NSWindow + 把被测视图塞进 contentView → 显式 `window.appearance =
/// .darkAqua/.aqua`（AppKit 向子树派发外观变更，无需真切系统外观）→ 断言 layer 色
/// **跟随翻转**到对应解算值。
///
/// ⚠️ 只锁钩子驱动的翻转，**不断言 init 裸解基线**：init 时视图无窗口，裸解兜底
/// 上下文 = App 级 effectiveAppearance（宿主明暗会拽走，实测双向成立），环境相关
/// 不是产品契约；产品钩子把解算钉进 performAsCurrentDrawingAppearance 后，
/// toDark/toLight 两个方向才逐位确定。
///
/// 铁律：tearDown 用 orderOut(nil)，禁 window.close()（多窗前脚 close → 后脚
/// RunLoop 自旋里 _NSWindowTransformAnimation dealloc SIGSEGV，见项目记忆）。
final class AppearanceRefreshTests: XCTestCase {
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        L10n.current = .en
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)   // 浅色起步（翻转断言的起点）
        window.animationBehavior = .none
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        L10n.current = .en
        super.tearDown()
    }

    private func install(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: window.contentLayoutRect)
        root.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.topAnchor.constraint(equalTo: root.topAnchor),
            v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
    }

    /// 系统动态色在深/浅两种 appearance 下的解算值。必须与产品代码逐位一致：产品钩子
    /// 写的是 performAsCurrentDrawingAppearance { color.cgColor }（不做 usingColorSpace），
    /// 这里同款裸 cgColor，否则深色通道分量不同的 ICC 解算会让 XCTAssertEqual 假红。
    private func resolved(_ color: NSColor) -> (light: CGColor, dark: CGColor) {
        var l: CGColor!
        var d: CGColor!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            l = color.cgColor
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            d = color.cgColor
        }
        return (l, d)
    }

    /// 切外观并同步派发。返回后视图钩子应已跑完。
    /// ⚠️ 同值再赋**不触发**派发——翻转断言必须走 toDark→toLight 两条不同值。
    private func toDark() {
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView?.subviews.forEach { $0.layoutSubtreeIfNeeded() }
    }

    private func toLight() {
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.subviews.forEach { $0.layoutSubtreeIfNeeded() }
    }

    private func bg(_ v: NSView) -> CGColor? { v.layer?.backgroundColor }
    private func border(_ v: NSView) -> CGColor? { v.layer?.borderColor }

    private func assertSameColor(_ a: CGColor?, _ b: CGColor?, _ m: String = "") {
        guard let a, let b else { XCTFail("nil color: \(m)"); return }
        XCTAssertEqual(a, b, m)
    }

    // MARK: - 探针：显式设 window.appearance 真的会派发到子树钩子？

    final class ProbeView: NSView {
        var fired = 0
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            fired += 1
        }
    }

    func testProbeExplicitAppearanceChangeFiresHook() {
        let p = ProbeView()
        install(p)
        window.display()
        let baseline = p.fired   // 入窗本身触发一次（外观首次解算），基线不是 0
        toDark()
        XCTAssertGreaterThan(p.fired, baseline, "显式设 window.appearance 必须向子树派发钩子")
    }

    // MARK: - 各视图：深→浅双向翻转逐位命中解算值

    func testBottomStatusBarBackgroundFollowsAppearance() {
        let bar = BottomStatusBar()
        install(bar)
        window.display()
        let ref = resolved(.windowBackgroundColor)
        toDark()
        assertSameColor(bg(bar), ref.dark, "切深色后底色须翻深")
        toLight()
        assertSameColor(bg(bar), ref.light, "切回浅色底色须翻浅")
    }

    func testCommandLineBarBackgroundFollowsAppearance() {
        let bar = CommandLineBar()
        install(bar)
        window.display()
        let ref = resolved(.windowBackgroundColor)
        toDark()
        assertSameColor(bg(bar), ref.dark, "命令栏底色须随外观")
        toLight()
        assertSameColor(bg(bar), ref.light, "命令栏底色切回须翻浅")
    }

    func testPaneBorderFollowsAppearance() {
        // 非活动窗格边框=separatorColor（动态色）——须双向随外观翻；活动边框=accent
        // 固定 RGBA（设计使然不随），故动态色测非活动态、恒定锁测活动态。
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try! "x".write(to: base.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let src = LocalFileSource()
        let left = FilePane(id: .left, source: src, startPath: TCPath(url: base))
        let right = FilePane(id: .right, source: src, startPath: TCPath(url: base))
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        let pv = PaneTableView(pane: right, workspace: ws, router: router, id: .right)
        left.load(); right.load()
        pv.setActive(false)   // 非活动 → 边框 separatorColor
        install(pv)
        window.display()
        let ref = resolved(.separatorColor)
        toDark()
        assertSameColor(border(pv), ref.dark, "切深色后非活动边框须翻深")
        toLight()
        assertSameColor(border(pv), ref.light, "切回浅色非活动边框须翻浅")

        // 活动态 accent 固定 RGBA：切外观后**不变**（锁住"固定主题色不随明暗"这条语义）。
        let pvA = PaneTableView(pane: left, workspace: ws, router: router, id: .left)
        pvA.setActive(true)
        install(pvA)
        window.display()
        let accBefore = border(pvA)
        toDark()
        assertSameColor(border(pvA), accBefore, "accent 边框跨明暗恒定")
    }

    func testFileCellBackgroundFollowsAppearance() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearancecell_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let it = base.appendingPathComponent("a.txt")
        try! "hello".write(to: it, atomically: true, encoding: .utf8)
        let src = LocalFileSource()
        let item = try! src.listDirectory(TCPath(url: base)).first(where: { $0.name == "a.txt" })!

        // 普通行底=controlBackgroundColor（动态）——双向随外观翻。
        let cell = FileCellView()
        install(cell)
        cell.configure(item: item, focus: false, marked: false, column: 0)
        window.display()
        let ref = resolved(.controlBackgroundColor)
        toDark()
        assertSameColor(bg(cell), ref.dark, "切深色后普通行底须翻深")
        toLight()
        assertSameColor(bg(cell), ref.light, "切回浅色普通行底须翻浅")

        // 焦点行底=selectedContentBackgroundColor（动态）——同款双向。真机回归曾定格
        // 浅白（钩子裸解撞上旧绘制上下文），钉外观解算后两向逐位命中。
        let cellF = FileCellView()
        install(cellF)
        cellF.configure(item: item, focus: true, marked: false, column: 0)
        window.display()
        let refF = resolved(.selectedContentBackgroundColor)
        toDark()
        assertSameColor(bg(cellF), refF.dark, "切深色后焦点行底须翻深")
        toLight()
        assertSameColor(bg(cellF), refF.light, "切回浅色焦点行底须翻浅")
    }

    func testThemedBackgroundViewFollowsAppearance() {
        let v = ThemedBackgroundView(color: .controlBackgroundColor)
        install(v)
        window.display()
        let ref = resolved(.controlBackgroundColor)
        toDark()
        assertSameColor(bg(v), ref.dark, "钩子路径须随外观重解底色（深）")
        toLight()
        assertSameColor(bg(v), ref.light, "钩子路径须随外观重解底色（浅）")
    }
}
