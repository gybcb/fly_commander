import XCTest
@testable import TCCore

/// 预览分派分类器逐格式锁（issue #3）。
/// 每条断言的变异映射见行内注释：删/改 PreviewKind.classify 的哪一行 → 哪条断言红。
final class PreviewKindTests: XCTestCase {
    private func k(_ ext: String) -> PreviewKind {
        PreviewKindClassifier.classify(filenameExtension: ext)
    }

    /// 回归「heic 掉二进制嗅探被误降级」真 bug（旧 imageExtensions 白名单没有 heic）：
    /// 变异=删 conforms(to:.image) 分支 → heic/png 全落 .text → 本测试红。
    func testImageFormatsIncludingHeicAndSVG() {
        for ext in ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic", "svg", "HEIC"] {
            XCTAssertEqual(k(ext), .image, "\(ext) 应走图片通道（旧白名单漏 heic 即本测试要钉的 bug）")
        }
    }

    /// 变异=删 conforms(to:.pdf) 分支 → pdf 落 .text → 红。
    func testPDF() {
        XCTAssertEqual(k("pdf"), .pdf)
        XCTAssertEqual(k("PDF"), .pdf, "大小写不敏感（classify 先 lowercased）")
    }

    /// 富文本四格式（rtfd 用字面扩展名判定——UTType 对 rtfd 解析出动态 identifier，
    /// 探针实测 identifier 集合/conforms 都锁不住）。
    /// 变异=richTextExtensions 集合漏 docx → docx 落 .text → 红；
    ///      改回 identifier 判定 → rtfd 行红（动态 id 不命中）。
    func testRichTextFormats() {
        for ext in ["rtf", "rtfd", "doc", "docx"] {
            XCTAssertEqual(k(ext), .richText, "\(ext) 应走 NSAttributedString 富文本文")
        }
    }

    /// 视频+音频都归 media（AVPlayerView 两者通吃）。
    /// 变异=删 conforms(to:.audio) → mp3 落 .text → 红；删 .movie → mp4 红。
    func testMediaFormats() {
        for ext in ["mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac"] {
            XCTAssertEqual(k(ext), .media, "\(ext) 应走媒体播放路")
        }
    }

    /// 诚实降级三件套（用户拍板：xlsx/pptx/iWork 无原生 API → .text 交嗅探自证降级）。
    /// 变异=把 xlsx 误加进 richTextExtensions → 红（ASText 读不出电子表格，探针实测）。
    func testHonestFallbackFormatsRouteToText() {
        for ext in ["xlsx", "pptx", "key", "pages", "numbers", "zip", "dmg"] {
            XCTAssertEqual(k(ext), .text, "\(ext) 应落文本路由嗅探降级（无原生预览 API）")
        }
    }

    /// html=读源码不渲染（用户拍板）；torrent 必须落 .text（forceTextExtensions 预览路
    /// 依赖它——变异=给 torrent 单开分支或归 richText → 现 torrent 预览回归红）。
    func testHTMLAndTorrentStayText() {
        XCTAssertEqual(k("html"), .text, "html 按用户裁定读源码不渲染")
        XCTAssertEqual(k("htm"), .text)
        XCTAssertEqual(k("torrent"), .text, "forceText 预览路的前提")
    }

    /// 无扩展名/未知扩展名 → .text（无扩展名纯文本是常见场景；未知=嗅探自证）。
    /// 变异=guard else return .fallback 化 → 无扩展名 txt 文件无法预览 → 该回归红。
    func testNoOrUnknownExtensionIsText() {
        XCTAssertEqual(k(""), .text)
        XCTAssertEqual(k("totallymadeupext"), .text)
    }

    /// TypeScript 源码钉回文本（评审 confirmed，本 diff 引入的回归）：UTType 把 "ts"
    /// 解析成 public.mpeg-2-transport-stream（conforms .movie=true）→ 不拦截则 F3 预览
    /// 变黑播放器。199 个常见源码/配置扩展名全扫：非文本命中只有 ts/mts 两个。
    /// 变异=删 forcedTextExtensions 拦截行 → 本条红；真 .m2ts 视频仍须 media（同条锁）。
    func testTypeScriptSourceStaysText() {
        for ext in ["ts", "mts", "TS", "MTS"] {
            XCTAssertEqual(k(ext), .text, "\(ext) 是 TypeScript 源码，不得被 transport-stream UTType 判成视频")
        }
        XCTAssertEqual(k("m2ts"), .media, "真 MPEG-2 transport 视频不受拦截影响")
    }
}
