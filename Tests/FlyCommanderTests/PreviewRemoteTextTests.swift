import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 远端文本文件 F3 直接预览（用户报「sftp 无法直接预览文本文件」）。
/// 契约=远端 **text 分类**条目经 FileSource.openReader 流读头部字节 → 复用本地
/// 同一套文本管线（isProbablyText 嗅探/截断横幅/长行）渲染；非 text 分类
/// （pdf/image/media/richText）远端维持降级页（渲染器只吃 file:// URL）。
/// 复用 SFTPServerFixture 真 sshd + PreviewRenderingSmokeTests 离屏真窗先例。
/// 环境不满足时自动 skip（见 SFTPServerFixture）。
final class PreviewRemoteTextTests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var source: SFTPSource!
    private var defaults: UserDefaults!
    private var vc: PreviewViewController!
    private var window: NSWindow!

    override func setUpWithError() throws {
        _ = NSApplication.shared   // 真窗夹具前置（PreviewRenderingSmokeTests 先例）
        defaults = UserDefaults(suiteName: "fly.previewremote.\(UUID().uuidString)")!
        fixture = SFTPServerFixture()
        guard let live = fixture.start() else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
        server = live
        let config = SFTPConnectionConfig(
            host: "127.0.0.1", port: UInt16(server.port),
            username: server.username,
            auth: .keyFile(path: server.keyPath, passphrase: server.keyPassphrase)
        )
        source = SFTPSource(config: config, homeDirectory: server.remoteBase.path,
                            hostKeyStore: SFTPHostKeyStore(defaults: defaults))

        PreviewWindowController.resetSharedForTest()
        guard let contentVC = PreviewWindowController.previewVCForTest() else {
            throw XCTSkip("预览 VC 不可用")
        }
        vc = contentVC
        vc.loadView()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none       // 动画 dealloc 悬垂 SIGSEGV（记忆坑）
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))   // 离屏不上屏
    }

    override func tearDown() {
        window?.orderOut(nil)
        PreviewWindowController.resetSharedForTest()
        vc = nil
        source?.closeConnection()
        source = nil
        fixture?.cleanup()
        fixture = nil
        server = nil
        defaults = nil
    }

    /// 往远端写文本/数据，返回真实 FileItem（经 list，size/date 与服务器一致）。
    @discardableResult
    private func writeRemote(_ name: String, _ data: Data) throws -> FileItem {
        let remotePath = server.remoteBase.path + "/" + name
        try source.streamWrite(tcPath(remotePath), totalBytes: Int64(data.count)) { [once = Ref(false)] in
            if once.value { return Data() }
            once.value = true
            return data
        }
        let items = try source.listDirectory(tcPath(server.remoteBase.path))
        guard let item = items.first(where: { $0.name == name }) else {
            throw FixtureError("远端 list 找不到刚写的 \(name)")
        }
        return item
    }

    /// 复用 SFTPSource 自身的编码构造（含 percent-encode），端口=服务器真端口。
    private func tcPath(_ remotePath: String) -> TCPath {
        SFTPSource.tcPath(host: "127.0.0.1", port: server.port, remotePath: remotePath)
    }

    /// 等异步（后台 openReader → 主线程换视图）落地。
    private func spin(_ seconds: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func firstSubview(ofType type: AnyClass) -> NSView? {
        func walk(_ v: NSView) -> NSView? {
            if v.isKind(of: type) { return v }
            for sub in v.subviews { if let hit = walk(sub) { return hit } }
            return nil
        }
        return walk(vc.view)
    }

    // MARK: - 主锁

    /// 远端 .txt F3 直接渲染文本（修复前必红：一切远端条目落降级页）。
    /// 变异证伪：show 远端分支删 .text 判定恒降级 → 无 NSTextView 红。
    func testRemoteTextFileRendersDirectly() throws {
        let item = try writeRemote("hello.txt", Data("远端内容 remote content\n第二行\n".utf8))
        vc.show(item: item, source: source)
        spin()
        let textView = try XCTUnwrap(
            firstSubview(ofType: NSTextView.self) as? NSTextView,
            "远端 text 必须渲染成 NSTextView（降级页=无）")
        XCTAssertTrue(textView.string.contains("remote content"),
                      "渲染内容须含夹具文本，实得：\(textView.string.prefix(80))")
        XCTAssertFalse(textView.isEditable, "预览必须只读")
        XCTAssertNil(firstSubview(ofType: NSButton.self) , "不得有降级页出口按钮")
    }

    /// 远端二进制（随机字节，控制字符密度高）→ 降级页嗅探拦截（护栏与本地同套）。
    /// 变异证伪：远端路删 isProbablyText 判定 → 建出 NSTextView 红。
    func testRemoteBinaryFallsBack() throws {
        var rnd = Data(count: 4096)
        for i in rnd.indices { rnd[i] = UInt8(truncatingIfNeeded: (i * 37) & 0x1F) }   // 全 <0x20 控制字符
        let item = try writeRemote("blob.dat", rnd)
        vc.show(item: item, source: source)
        spin()
        XCTAssertNil(firstSubview(ofType: NSTextView.self), "二进制不得渲染成文本")
        XCTAssertNotNil(firstSubview(ofType: NSButton.self), "应落降级页（含出口按钮）")
    }

    /// 远端大文件（>512KB）→ 只读头部 + 截断横幅（护栏与本地同套）。
    /// 变异证伪：远端泵读不设 textPreviewLimit 上限 → 整档读入（仍渲染，但 totalBytes
    ///   用 item.size 判 truncated 恒真 → 此断言仍绿，抓不到上限漏）。故**额外直测**
    ///   previewText 纯函数上限见 PreviewTextLoadingTests。
    func testRemoteLargeTextTruncatedWithBanner() throws {
        let line = "0123456789012345678901234567890123456789012345678901234567890123456789\n"
        let reps = (600 * 1024) / line.utf8.count
        var s = ""
        for _ in 0..<reps { s += line }
        let item = try writeRemote("big.txt", Data(s.utf8))
        XCTAssertGreaterThan(item.size, 512 * 1024, "前置：夹具必须超 512KB")
        vc.show(item: item, source: source)
        spin(3.0)
        let textView = try XCTUnwrap(
            firstSubview(ofType: NSTextView.self) as? NSTextView,
            "超大远端文本应渲染（带截断横幅），不得整页降级")
        XCTAssertGreaterThan(textView.string.count, 1000)
        let labels = collectLabels()
        // 默认语言=英文（L10n 出厂默认）；en 横幅="Showing only first …"
        XCTAssertTrue(labels.contains { $0.contains("Showing only first") },
                      "截断横幅文案必须在场，实得：\(labels)")
    }

    /// token 竞态：远端大文件在途 → 立刻改 preview 别的条目 → 陈旧结果不得覆盖末次。
    /// 变异证伪：远端路不经 showAsync token 校验 → 陈旧大文件回主线程覆盖末次 → 末次
    ///   非大文件内容不在场（断言末次内容在场）。
    func testStaleRemoteLoadDroppedByToken() throws {
        let line = "x".repeating(200) + "\n"
        let reps = (900 * 1024) / line.utf8.count
        var big = ""
        for _ in 0..<reps { big += line }
        let bigItem = try writeRemote("stale_big.txt", Data(big.utf8))

        let small = try writeRemote("after.txt", Data("末次小文件 FINAL".utf8))

        vc.show(item: bigItem, source: source)      // 远端慢读在途
        vc.show(item: small, source: source)        // 立刻改主意 → token 作废上一次
        spin(3.0)
        let textView = firstSubview(ofType: NSTextView.self) as? NSTextView
        XCTAssertEqual(textView?.string, "末次小文件 FINAL",
                       "末次预览必须胜出（陈旧远端读结果被 token 丢弃）")
    }

    private func collectLabels() -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let tf = v as? NSTextField { out.append(tf.stringValue) }
            for sub in v.subviews { walk(sub) }
        }
        walk(vc.view)
        return out
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

private final class Ref<T> { var value: T; init(_ v: T) { value = v } }

private extension String {
    func repeating(_ n: Int) -> String { String(repeating: self, count: n) }
}
