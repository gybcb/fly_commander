import AppKit
import PDFKit
import AVKit
import TCCore

final class PreviewViewController: NSViewController {
    /// 文本预览只加载文件开头这么多字节：排版/滚动开销随字符数走，
    /// 1.5MB 文件滚动已实测变慢 → 上限取 512KB 保证流畅，超出走截断横幅。
    private static let textPreviewLimit = 512 * 1024
    /// 超过此大小的文件直接走二进制降级（不再读取）。
    private static let textMaxBytes = 512 * 1024 * 1024
    /// 富文本整档读入上限（PDF/media 无此风险：PDFKit 懒排版、播放器不读全文）。
    /// 依据=评审实测放大比（见 show .richText 注释）：16MB 文件已能膨胀出
    /// 数百万字符 TextKit 文档，再往上主线程排版不可接受 → 直接降级页。
    static let richTextMaxBytes = 16 * 1024 * 1024
    /// 单行上限：TextKit 的排版量/文档高度随单行字符数走（probe 实测 524K 字符
    /// 单行 → 78645pt document view，且曾导致预览区空白）→ 超长行截到此值。
    static let textLineLimit = 32 * 1024
    /// 长行截断处的可见标记（UI 测试按此文案断言）。计算属性：若用 static let 会在首次
    /// 访问时把文案冻结进进程生命周期，语言切换后截断标记仍停在启动语言。
    static var longLineMarker: String { L10n.t(.lineTruncatedMark) }
    /// 这些扩展名**跳过二进制嗅探**直接按文本预览：.torrent 是 bencode 文本 +
    /// piece 哈希二进制块，哈希里的 NUL/控制字节能占到前 8KB 的 50%（多 piece 时），
    /// 任何"NUL/密度"嗅探都会误判（用户实测小 .torrent 无法预览）；哈希字节按
    /// UTF-8 解出替换符显示，可读部分（tracker/name）正常——与 TC 预览行为一致。
    static let forceTextExtensions: Set<String> = ["torrent"]

    /// 有界文本读取结果。纯 Foundation，便于单测。
    struct PreviewText {
        let text: String        // 解码后文本（≤ limit 字节，单行 ≤ textLineLimit）
        let totalBytes: Int64   // 文件实际大小
        let truncated: Bool     // 是否被字节上限截断
        let longLineTruncated: Bool  // 是否有单行被 textLineLimit 截断
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
    }

    /// 语言切换重刷绑定：闭包捕获控件 + key，刷新时按当前语言重算 t() 回写。
    /// 每次 show(item:) 会丢弃旧内容重建 → show 开头清空绑定，只绑本轮真正静态的控件。
    private var localizedBindings: [() -> Void] = []
    private func bind(_ field: NSTextField, _ key: L10nKey) {
        localizedBindings.append { field.stringValue = L10n.t(key) }
    }
    private func bind(_ button: NSButton, _ key: L10nKey) {
        localizedBindings.append { button.title = L10n.t(key) }
    }

    /// 语言变更后重刷当前已显示内容里的静态控件（"用默认应用打开"按钮、降级标题等）。
    /// 动态串（含文件名的横幅文案/路径/图片失败提示、窗口标题）随下次 show 现取，不绑。
    /// 视图未加载（单例从未预览过任何文件）时绑定表为空 → 无操作，不强开窗口。
    func refreshLocalizedText() {
        localizedBindings.forEach { $0() }
    }


    /// Esc 关闭预览窗（NSWindow 把 cancelOperation 派发到响应链；
    /// 焦点在文本区/横幅按钮上时同样能关）。
    override func cancelOperation(_ sender: Any?) {
        view.window?.performClose(nil)
    }

    /// 关窗停播挂点：performClose 对单例窗只是隐藏（isReleasedWhenClosed=false，
    /// contentView 不离窗 → viewDidDisappear 生产里根本不来——评审回归锁抓出）→ 挂窗的
    /// willCloseNotification。show 时窗必已存在（present 先置 contentViewController 再
    /// show）；按窗身份去重，换窗（测试夹具）也能重挂。VC 单例永生 → observer 不用摘。
    private var pauseObserverWindow: NSWindow?
    private func registerClosePauseIfNeeded() {
        guard let w = view.window, pauseObserverWindow !== w else { return }
        pauseObserverWindow = w
        NotificationCenter.default.addObserver(self, selector: #selector(pauseForWindowClose),
                                               name: NSWindow.willCloseNotification, object: w)
    }
    @objc private func pauseForWindowClose() { currentPlayer?.pause() }

    /// 每次 show 自增；异步加载（PDF/富文本）回主线程时校验 `token == showToken`，
    /// 丢弃被更新预览覆盖的陈旧结果。单例预览窗 + F3 快连按是最真竞态。
    /// token 只丢结果不中断已在途的读（PDFDocument/NSAttributedString 无 cancel API）——
    /// 快连按会瞬发几个后台读，每个 ≤ 数十 MB 且有 .userInitiated 优先级，是有界浪费非泄漏。
    private var showToken = 0

    /// 当前媒体预览的 player（仅 .media 路赋值，弱于窗口生命周期）。AVPlayer 不随
    /// AVPlayerView 离树/关窗自动停（评审实测）→ show 开头 + 关窗通知两处 pause。
    private var currentPlayer: AVPlayer?
    #if DEBUG
    /// 测试用：断言 pause 收口真的握住了 player（rate 翻转合同，见 PreviewRenderingSmokeTests）。
    var currentPlayerForTest: AVPlayer? { currentPlayer }
    #endif

    func show(item: FileItem) {
        localizedBindings.removeAll()   // 旧内容即将丢弃，绑定随之作废
        registerClosePauseIfNeeded()
        showToken += 1
        let token = showToken
        fallbackURL = item.path.url
        let url = item.path.url
        // 正在播的媒体必须在这里停：AVPlayer 不随视图移除/关窗而停（评审实测：换文件
        // 后播放头仍推进，直到曲目播完）。pause 收口在 show 开头 + willClose 通知，
        // 覆盖「预览下一个文件」与「关窗」两条路。
        currentPlayer?.pause()
        // 远端文件（sftp://… / smb://…）不进任何渲染路：AVPlayer/PDFKit/ASText 都不吃
        // scheme URL（评审实证 remote mp4 只剩播放器空壳，丢了旧版降级页的提示+出口）。
        // 与命令行 view 命令的 remoteNoPreview 合同同向；降级页给出路径 + 复制路径出口。
        // token 已自增 → 在途的本地异步加载照样作废。
        if item.path.isRemote {
            swapContent(makeFallbackView(item: item))
            return
        }
        // 异步路（pdf/富文本）自带占位换视图，不进同步 switch。
        // 后台只做数据加载（PDF 解析/docx zip 解压可能几十~几百 ms），**AppKit 视图
        // 一律主线程构造**——load 返回 nil（加载失败）→ 主线程降级页。
        switch PreviewKindClassifier.classify(filenameExtension: url.pathExtension) {
        case .pdf:
            showAsync(token: token, load: { PDFDocument(url: url) },
                      fallback: { self.makeFallbackView(item: item) },
                      on: { (doc: PDFDocument?) in
                guard let doc, doc.pageCount > 0 else { return nil }
                return self.makePDFContent(document: doc)
            })
        case .richText:
            // 尺寸上限：TextKit 排版量/常驻随字符数走（评审实测 23MB RTF → 312MB 常驻、
            // 首次全量排版主线程独占 ~5-7s；340KB docx 可膨胀 5 万倍）——旧文本路的
            // 护栏同理由（见 textPreviewLimit 注释）。超限直接降级页，「用默认应用打开」
            // 仍可达；上限取 16MB 文件（实测 docx 展开 ≤ ~700 万字符 ≈ 1.4s 排版）。
            showAsync(token: token,
                      load: {
                guard let size = Self.fileSize(url), size <= Self.richTextMaxBytes else { return nil }
                return try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
            },
                      fallback: { self.makeFallbackView(item: item) },
                      on: { (ast: NSAttributedString?) in
                guard let ast, ast.length > 0 else { return nil }
                return self.makeRichTextContent(attributedString: ast)
            })
        case .image:
            swapContent(makeImageView(url: url))
        case .media:
            swapContent(makeMediaView(url: url))
        case .text:
            if let pt = Self.loadPreviewText(url: url, limit: Self.textPreviewLimit) {
                swapContent(makeTextView(url: url, item: item, text: pt))
            } else {
                swapContent(makeFallbackView(item: item))
            }
        }
    }

    /// 后台加载数据 → 主线程 token 校验（仍是最新预览才换视图）→ 用结果建视图，
    /// 加载失败（on 返回 nil）走 fallback 降级页。token 只丢结果不中断在途读
    /// （PDFDocument/NSAttributedString 无 cancel）——快连按瞬发几个后台读，各有界
    /// （≤文件大小、.userInitiated），是有界浪费非泄漏。队列只用系统预建全局队列
    /// （SDK 约束：绝不动态建 DispatchQueue）。
    private func showAsync<T>(token: Int,
                              load: @escaping @Sendable () -> T?,
                              fallback: @escaping () -> NSView,
                              on: @escaping (T?) -> NSView?) {
        let placeholder = NSView()
        placeholder.wantsLayer = true
        placeholder.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        swapContent(placeholder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = load()
            DispatchQueue.main.async {
                guard let self, token == self.showToken else { return }
                self.swapContent(on(loaded) ?? fallback())
            }
        }
    }

    /// 换掉整块内容视图（约束铺满 view）。程序化子视图必须关 autoresizing mask（SDK 约束）。
    private func swapContent(_ content: NSView) {
        for subview in view.subviews { subview.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// 预览侧「文件字节数」：普通文件直读；目录（=包，rtfd 等）递归求和并设硬顶早停
    /// （只为尺寸守卫服务，不求精确——超顶必然超守卫）。无 fileSizeKey 会把目录判成
    /// 尺寸未知 → 富文本守卫全盲（评审回归锁 testRTFDDirectoryPackageLoads 抓出）。
    static let packageScanCap = 256 * 1024 * 1024
    private static func fileSize(_ url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { return nil }
        if v.isDirectory == true {
            var total: Int64 = 0
            guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
                return 0
            }
            for case let f as URL in en {
                let s = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                total += s
                if total > Int64(packageScanCap) { return total }   // 早停：已远超任何守卫
            }
            return total
        }
        guard let n = v.fileSize else { return nil }
        return Int64(n)
    }

    /// 只读文件开头 `limit` 字节做文本预览。
    /// - 文件 > textMaxBytes → nil（走二进制降级）
    /// - 非 `forceTextExtensions` 且 head 控制字符密度超阈值 → nil（二进制）
    /// - 读取失败 → nil
    /// - 空文件 → 空文本（正常显示空白）
    /// - 单行超过 textLineLimit → 截断该行并追加 `longLineMarker`
    static func loadPreviewText(url: URL, limit: Int) -> PreviewText? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let total = Int64(values.fileSize ?? 0)
        guard total <= Int64(textMaxBytes) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = handle.readData(ofLength: limit)
            let forceText = Self.forceTextExtensions.contains(url.pathExtension.lowercased())
            if !forceText, !Self.isProbablyText(head) { return nil }
            let raw = String(decoding: head, as: UTF8.self)
            let (text, longLineTruncated) = truncateLongLines(raw)
            return PreviewText(text: text,
                               totalBytes: total,
                               truncated: total > Int64(head.count),
                               longLineTruncated: longLineTruncated)
        } catch {
            return nil
        }
    }

    /// 二进制判定：前 8KB 控制字符（<0x20，含 NUL；跳过 \t\r\n）密度 > 2%。
    /// "含 NUL 即二进制"会把 .torrent 这类"文本为主、夹 piece 哈希二进制块"
    /// 的文件误判为二进制（用户实测小 .torrent 无法预览）；密度阈值放行它。
    static func isProbablyText(_ head: Data) -> Bool {
        guard !head.isEmpty else { return true }
        let sniff = head.prefix(8192)
        let control = sniff.reduce(0) { total, byte in
            (byte < 0x20 && byte != 0x09 && byte != 0x0D && byte != 0x0A) ? total + 1 : total
        }
        return Double(control) / Double(sniff.count) <= 0.02
    }

    /// 单行超过 `textLineLimit` 字符的行截断到上限并追加标记。
    /// 纯函数，O(n)；多行文件（各行 ≤ 上限）返回原样、标志为 false，
    /// 换行结构（含尾换行）逐字节保持。
    static func truncateLongLines(_ raw: String) -> (text: String, truncated: Bool) {
        var truncated = false
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.count > textLineLimit {
                truncated = true
                return String(line.prefix(textLineLimit)) + longLineMarker
            }
            return String(line)
        }
        return (lines.joined(separator: "\n"), truncated)
    }

    private func makeTextView(url: URL, item: FileItem, text pt: PreviewText) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        guard let text = scroll.documentView as? NSTextView else {
            return makeFallbackView(item: item)
        }
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.string = pt.text
        fallbackURL = url

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        var topAnchor = container.topAnchor
        var topConstant: CGFloat = 8
        if pt.truncated || pt.longLineTruncated {
            let banner = makeTruncationBanner(totalBytes: pt.totalBytes, longLineTruncated: pt.longLineTruncated)
            container.addSubview(banner)
            banner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            ])
            topAnchor = banner.bottomAnchor
            topConstant = 4
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    /// 截断横幅：文案 + "用默认应用打开"小按钮（看全量内容的出口）。
    /// 横幅必须有确定性高度——label 若只 centerY 钉住，横幅高度歧义，
    /// Auto Layout 会把 scroll 压到 0 高（probe 复现：文字区消失、无滚动条）。
    private func makeTruncationBanner(totalBytes: Int64, longLineTruncated: Bool) -> NSView {
        var message = L10n.t(.previewTruncBanner, ByteCountFormatter().string(fromByteCount: Int64(Self.textPreviewLimit)))
            + L10n.t(.previewOfFileTotal, ByteCountFormatter().string(fromByteCount: totalBytes))
        if longLineTruncated {
            message += L10n.t(.previewLongLineTrunc, ByteCountFormatter().string(fromByteCount: Int64(Self.textLineLimit)))
        }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: L10n.t(.openWithDefault), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(openWithDefaultApplication)
        bind(button, .openWithDefault)   // 静态按钮标题；横幅文案含字节数（动态）随下次 show 现取，不绑

        let banner = NSView()
        banner.addSubview(label)
        banner.addSubview(button)
        NSLayoutConstraint.activate([
            banner.heightAnchor.constraint(equalToConstant: 28),
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
        ])
        return banner
    }

    private func makeImageView(url: URL) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        if let image = NSImage(contentsOf: url) {
            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                imageView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
                imageView.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -24),
            ])
        } else {
            let label = NSTextField(labelWithString: L10n.t(.cannotReadImage, url.lastPathComponent))
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }
        return container
    }

    /// PDF 预览：PDFKit PDFView（探针实证本 SDK 存活面 = document/autoScales/displayMode，
    /// displayModeOptions 被剥——别「顺手加」，编译不过）。document 由调用方在后台加载并
    /// 确认 pageCount>0 后传入；挂载点必须关 autoresizing mask（SDK 约束）。
    private func makePDFContent(document: PDFDocument) -> NSView {
        let pdfView = PDFView(frame: .zero)
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// 富文本预览（rtf/rtfd/doc/docx 的 NSAttributedString 结果）：只读 NSTextView。
    /// **不套等宽字体**——setAttributedString 后保留文档自带字体/颜色（富文本的意义）。
    private func makeRichTextContent(attributedString: NSAttributedString) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        guard let text = scroll.documentView as? NSTextView,
              let storage = text.textStorage else {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            return v
        }
        text.isEditable = false
        text.isSelectable = true
        storage.setAttributedString(attributedString)
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    /// 媒体预览（视频/音频共用 AVPlayerView）。**属性面刻意的窄**：本缩减 SDK 里
    /// controlsVisible/videoGravity 等被剥（探针实测），只碰 player 挂载——后人别加。
    /// 不自动 play()：打开预览即自动出声是惊吓不是特性，用户按控件播放。
    /// player 存进 currentPlayer → show 开头 + 关窗 willClose 两处统一 pause（离树/关窗
    /// 不停播是 AVPlayer 实测行为，见 currentPlayer 注释；viewDidDisappear 不可靠，
    /// 见 registerClosePauseIfNeeded 注释）。
    private func makeMediaView(url: URL) -> NSView {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView(frame: .zero)
        playerView.player = player
        playerView.translatesAutoresizingMaskIntoConstraints = false
        currentPlayer = player
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeFallbackView(item: FileItem) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: L10n.t(.cannotPreview))
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        bind(title, .cannotPreview)   // 静态降级标题；下方 pathLabel 含文件路径（动态）不绑

        let pathLabel = NSTextField(labelWithString: item.path.displayString())
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.isSelectable = true
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: L10n.t(.openWithDefault), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(openWithDefaultApplication)
        bind(button, .openWithDefault)
        fallbackURL = item.path.url

        let stack = NSStackView(views: [title, pathLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private var fallbackURL: URL?

    @objc private func openWithDefaultApplication() {
        guard let url = fallbackURL else { return }
        NSWorkspace.shared.open(url)
    }
}
