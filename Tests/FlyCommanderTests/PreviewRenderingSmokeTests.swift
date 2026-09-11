import XCTest
import AppKit
import PDFKit
import AVKit
@testable import FlyCommander
import TCCore

// MARK: - issue #3「预览支持文件太少」渲染层冒烟锁
//
// 分类器（PreviewKindTests）只锁「走哪条路」；本类锁「路本身走得通」：
// PDFKit 挂载、NSAttributedString 无提示嗅探读 rtf/docx/rtfd、AVPlayerView 构造
// （缩减 SDK 属性面）、showToken 竞态。全部探针（/tmp/qlprobe probe2/4/7/8）背书。

/// 真窗夹具：PreviewWindowController 是单例（reset 后首次 create 不 orderFront，
/// 避开 SIGSEGV 动画坑），内容 VC 直接 show 到自建离屏窗口驱动布局。
private final class PreviewFixture {
    let dir: URL
    let vc: PreviewViewController
    let window: NSWindow

    init() throws {
        // 裸测试进程不 touch NSApplication → url-based NSAttributedString 崩
        // unrecognized selector（探针实证：AppKit 文档读取器懒加载没踢）。真 app 恒安全。
        _ = NSApplication.shared
        PreviewWindowController.resetSharedForTest()
        guard let vc = PreviewWindowController.previewVCForTest() else {
            throw NSError(domain: "fixture", code: 1)
        }
        self.vc = vc
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none   // 动画 dealloc 悬垂 SIGSEGV（issue #1 记忆坑）
        window.isReleasedWhenClosed = false   // performClose 后夹具窗要活得过 tearDown
        window.contentViewController = vc
        vc.loadView()
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))   // 离屏，不上屏
    }

    func item(_ name: String) -> FileItem {
        let url = dir.appendingPathComponent(name)
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        return FileItem(id: url.path, path: TCPath(url: url), name: name, isDirectory: false,
                        size: size, modificationDate: Date(timeIntervalSince1970: 0),
                        isHidden: false, isReadOnly: false, isExecutable: false)
    }

    /// 等异步加载（PDF/富文本后台读 → 主线程换视图）落地。
    func spin(_ seconds: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func firstSubview(ofType type: AnyClass) -> NSView? {
        func walk(_ v: NSView) -> NSView? {
            if v.isKind(of: type) { return v }
            for sub in v.subviews { if let hit = walk(sub) { return hit } }
            return nil
        }
        return walk(vc.view)
    }

    func tearDown() {
        // 禁 close()：_NSWindowTransformAnimation dealloc 悬垂 SIGSEGV（记忆坑）→ orderOut
        window.orderOut(nil)
        PreviewWindowController.resetSharedForTest()
        try? FileManager.default.removeItem(at: dir)
    }
}

final class PreviewRenderingSmokeTests: XCTestCase {
    private var fx: PreviewFixture!

    override func setUpWithError() throws { fx = try PreviewFixture() }
    override func tearDownWithError() throws { fx.tearDown(); fx = nil }

    // MARK: - 夹具

    /// textutil 造富文本夹具（探针先例）：txt → rtf/docx/doc/rtfd。
    private func textutil(_ name: String, to format: String) throws -> URL {
        let src = fx.dir.appendingPathComponent("\(name).src.txt")
        try "标题内容 Title content".write(to: src, atomically: true, encoding: .utf8)
        let out = fx.dir.appendingPathComponent("\(name).\(format)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        p.arguments = ["-convert", format, src.path, "-output", out.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "textutil -convert \(format) 造夹具失败")
        return out
    }

    /// 代码造最小合法 PDF（PDF 1.4 单页，xref 偏移手工核对过——PDFKit 容忍偏移
    /// 不精确但字节必须完整；探针同款）。
    private func writeMinimalPDF(_ name: String) throws -> URL {
        let body = """
        %PDF-1.4
        1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
        2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
        3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
        trailer<</Root 1 0 R/Size 4>>
        %%EOF
        """
        let url = fx.dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .ascii)
        return url
    }

    // MARK: - PDF

    /// PDF → PDFView 且 document 已挂。
    /// 变异=show 的 .pdf case 删 `document=doc` 挂载 → document nil 红；
    ///      .pdf case 整个删（落 .text）→ 找不到 PDFView 红。
    func testPDFLoadsIntoPDFView() throws {
        let url = try writeMinimalPDF("sample.pdf")
        XCTAssertNotNil(PDFDocument(url: url), "前置：夹具 PDF 必须合法")
        fx.vc.show(item: fx.item("sample.pdf"))
        fx.spin()
        let pdfView = try XCTUnwrap(fx.firstSubview(ofType: PDFView.self) as? PDFView)
        XCTAssertNotNil(pdfView.document, "PDFView 必须挂上文档（分类对但没挂载即此红）")
        XCTAssertEqual(pdfView.document?.pageCount, 1)
    }

    /// 坏 PDF（扩展名 pdf、内容二进制垃圾）→ 降级页不崩。
    /// 变异=删 `guard doc != nil, pageCount > 0 else nil` → 空/坏文档进 PDFView。
    func testBadPDFFallsBackWithoutCrash() throws {
        let url = fx.dir.appendingPathComponent("broken.pdf")
        try Data(repeating: 0x00, count: 512).write(to: url)
        fx.vc.show(item: fx.item("broken.pdf"))
        fx.spin()
        XCTAssertNil(fx.firstSubview(ofType: PDFView.self), "坏 PDF 不得进 PDFView")
        // 降级页含「用默认应用打开」按钮（cannotPreview 页的出口）
        XCTAssertNotNil(fx.firstSubview(ofType: NSButton.self), "应落降级页（含打开按钮）")
    }

    // MARK: - 富文本（无提示嗅探合同）

    /// rtf/docx/doc 三格式 url-based NSAttributedString 读通 → 富文本视图。
    /// 变异=load 闭包加显式 type 提示 → Cocoa 65806 读 nil → 降级页红（探针实测
    ///   显式 docx type 反而失败，「无提示」是硬合同）；
    /// 变异=.richText case 删 → 落 .text 二进制嗅探 → docx 判二进制降级红。
    func testRichTextFormatsRender() throws {
        for format in ["rtf", "docx", "doc"] {
            try textutil("doc_\(format)", to: format)
            fx.vc.show(item: fx.item("doc_\(format).\(format)"))
            fx.spin()
            let textView = try XCTUnwrap(
                fx.firstSubview(ofType: NSTextView.self) as? NSTextView,
                "\(format) 应渲染成富文本 NSTextView")
            XCTAssertGreaterThan(textView.string.count, 0, "\(format) 读出的内容必须非空")
            XCTAssertTrue(textView.string.contains("Title"), "\(format) 内容应含夹具文本")
            XCTAssertFalse(textView.isEditable, "预览必须只读")
        }
    }

    /// rtfd 是目录包：**只能 url-based** 读。变异=「优化」成先读 Data 再 data-based
    /// → rtfd 读不出（探针实测）→ 本条红。VC 路 + 直读双断言（只直读抓不到
    /// 「分派对但生产侧改坏 data-based」这半边）。
    func testRTFDDirectoryPackageLoads() throws {
        let url = try textutil("bundle", to: "rtfd")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let ast = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
        XCTAssertNotNil(ast, "rtfd 目录包 url-based 必须能读（data-based 读不了）")
        XCTAssertGreaterThan(ast?.length ?? 0, 0)
        // VC 全路：rtfd 经 .richText 分派 → 富文本视图渲染出夹具内容
        fx.vc.show(item: fx.item("bundle.rtfd"))
        fx.spin()
        let textView = try XCTUnwrap(fx.firstSubview(ofType: NSTextView.self) as? NSTextView)
        XCTAssertTrue(textView.string.contains("Title"), "rtfd 必须经 VC 路渲染出内容")
    }

    // MARK: - 媒体

    /// AVPlayerView 构造 + player 挂载（构造本身防「引入被剥属性 → 编译红」；
    /// player 挂载防「分类对但没接上」）。不自动 play 是产品决定，不锁运行时行为。
    /// 变异=.media case 删 player 赋值 → player nil 红。
    func testMediaBuildsPlayerView() throws {
        let url = fx.dir.appendingPathComponent("clip.mp4")
        try Data(repeating: 0, count: 64).write(to: url)   // 假媒体：AVPlayer 构造不解析
        fx.vc.show(item: fx.item("clip.mp4"))
        fx.spin()
        let pv = try XCTUnwrap(fx.firstSubview(ofType: AVPlayerView.self) as? AVPlayerView)
        XCTAssertNotNil(pv.player, "AVPlayerView 必须挂 player")
    }

    /// 评审 major 修复锁：播中换文件/关窗必须停播（AVPlayer 离树不停播，评审实测
    /// 播放头持续推进直到曲终）。XCTest 进程媒体服务可用（评审探针实证）；断言用
    /// rate 翻转（play/pause 的合同面，不依赖出声）。
    /// 变异=删 show 开头的 currentPlayer?.pause() → 「换文件后」rate 仍 >0 红；
    ///      删 pauseForWindowClose 的 pause → 「关窗后」rate 仍 >0 红。
    func testPlayingMediaPausesOnSwitchAndClose() throws {
        let url = fx.dir.appendingPathComponent("clip.mp4")
        try Data(repeating: 0, count: 64).write(to: url)
        fx.vc.show(item: fx.item("clip.mp4"))
        fx.spin()
        let player = try XCTUnwrap(fx.vc.currentPlayerForTest, "makeMediaView 必须把 player 存进 VC")
        player.play()
        XCTAssertGreaterThan(player.rate, 0, "前置：play 后 rate 应 >0")

        let txt = fx.dir.appendingPathComponent("next.txt")
        try "next".write(to: txt, atomically: true, encoding: .utf8)
        fx.vc.show(item: fx.item("next.txt"))
        XCTAssertEqual(player.rate, 0, "换文件后必须停播（show 开头 pause 被删即此红）")

        // 关窗路：performClose 触发 willCloseNotification（生产关窗路径；测试窗
        // animationBehavior=.none 规避 close 动画 dealloc SIGSEGV 记忆坑）
        player.play()
        XCTAssertGreaterThan(player.rate, 0, "前置：二次 play 后 rate 应 >0")
        fx.window.performClose(nil)
        fx.spin(0.3)
        XCTAssertEqual(player.rate, 0, "关窗后必须停播（willClose pause 被删即此红）")
    }

    // MARK: - 远端守卫（评审 major）

    /// sftp:// scheme 不进任何渲染路（AVPlayer 吃 remote URL 只剩空壳播放器，丢提示+出口）。
    /// 变异=删 show 的 isRemote 早退 → mp4 走 .media 建出 AVPlayerView → 「无 AVPlayerView」红。
    /// 用 .mp4 而非 .pdf 鉴别：远端 PDF 就算删守卫也 PDFDocument(url:)=nil 落降级页=假绿。
    func testRemoteItemFallsBackWithoutRenderer() throws {
        let remote = TCPath("sftp://example.invalid:22/videos/clip.mp4")
        XCTAssertTrue(remote.isRemote, "前置：夹具路径必须远端")
        let item = FileItem(id: "r1", path: remote, name: "clip.mp4", isDirectory: false,
                            size: 1024, modificationDate: Date(timeIntervalSince1970: 0),
                            isHidden: false, isReadOnly: false, isExecutable: false)
        fx.vc.show(item: item)
        fx.spin()
        XCTAssertNil(fx.firstSubview(ofType: AVPlayerView.self), "远端不得进 media 渲染路")
        XCTAssertNil(fx.firstSubview(ofType: PDFView.self))
        XCTAssertNotNil(fx.firstSubview(ofType: NSButton.self), "应落降级页（含出口按钮）")
    }

    // MARK: - 富文本尺寸上限（评审 major：23MB RTF → 312MB 常驻 + 排版冻主线程数秒）

    /// 17MB 合法 RTF（>16MB 上限）→ 降级页，不整档读入。夹具=合法 RTF header+重复
    /// 正文（探针实证无守卫时 url-based 整档读出 17,825,760 字符 → 「不守卫必渲染出
    /// 内容」非同义反复，守卫拦截才有降级）。
    /// 变异=删 load 里 fileSize 守卫 → 整档读入建出 NSTextView → 「无 NSTextView」红。
    func testOversizedRichTextFallsBackWithoutReading() throws {
        let unit = "Hello preview guard test 0123456789 "
        var s = "{\\rtf1\\ansi\\deff0 "
        for _ in 0..<((17 * 1024 * 1024) / unit.utf8.count) { s += unit }
        s += "}"
        let url = fx.dir.appendingPathComponent("huge.rtf")
        try s.write(to: url, atomically: true, encoding: .ascii)
        XCTAssertGreaterThan(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                             PreviewViewController.richTextMaxBytes, "前置：夹具必须超上限")
        fx.vc.show(item: fx.item("huge.rtf"))
        fx.spin(3.0)
        XCTAssertNil(fx.firstSubview(ofType: NSTextView.self), "超上限富文本必须直接降级（读前守卫）")
        XCTAssertNotNil(fx.firstSubview(ofType: NSButton.self), "应落降级页（含出口按钮）")
    }

    // MARK: - token 竞态（单例预览窗 + F3 快连按）

    /// 连按两个文件（大 PDF 先、小 txt 后）：末次必须胜出。
    /// 变异=删 showAsync 的 `token == showToken` 校验 → 大 PDF 后台读完后覆盖
    /// txt 内容 → 「无 PDFView」红（首内容覆盖末内容）。
    func testRapidSuccessiveShowsLastWins() throws {
        // 复制成大 PDF 拖慢后台读（保证它在 txt 之后才回主线程）
        let url = try writeMinimalPDF("slow.pdf")
        var data = try Data(contentsOf: url)
        data.append(Data(repeating: 0x20, count: 8 * 1024 * 1024))
        try data.write(to: url)

        let txt = fx.dir.appendingPathComponent("after.txt")
        try "plain text".write(to: txt, atomically: true, encoding: .utf8)

        fx.vc.show(item: fx.item("slow.pdf"))     // 异步加载起步
        fx.vc.show(item: fx.item("after.txt"))    // 立刻改主意 → token 作废上一次
        fx.spin(3.0)

        XCTAssertNil(fx.firstSubview(ofType: PDFView.self),
                     "陈旧 PDF 结果不得覆盖末次预览（token 校验被删即此红）")
        XCTAssertNotNil(fx.firstSubview(ofType: NSTextView.self), "末次 txt 预览必须在场")
    }
}
