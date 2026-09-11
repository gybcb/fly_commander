import Foundation
import UniformTypeIdentifiers

/// 预览分派分类（issue #3）：扩展名 → 预览通道。纯 Foundation（UTType），零 AppKit/零 I/O。
/// 只判定「走哪条渲染路」，不判定「文件能否打开」——pdf/richText/media 渲染器自带失败降级；
/// text 通道再由 PreviewViewController 的二进制嗅探自证（xlsx 等 zip 落这里→嗅探判二进制→降级）。
public enum PreviewKind: Equatable {
    case image      // NSImage 直读
    case pdf        // PDFKit
    case richText   // NSAttributedString(url:, options:[:]) 自动嗅探（rtf/rtfd/doc/docx）
    case media      // AVKit AVPlayerView（视频/音频，用户按播放）
    case text       // 有界文本读 + 二进制嗅探（含 html=读源码不渲染，用户裁定）
}

public enum PreviewKindClassifier {
    /// NSAttributedString 能读的文档格式（探针实测读取必须**无类型提示**；这里只分类不读取）。
    /// 用字面扩展名而非 UTType identifier：rtfd 经 filenameExtension 解析出的是动态
    /// identifier（dyn.…），identifier 集合/ conforms 都锁不住（探针实测）；扩展名判定确定可靠。
    /// iWork（key/pages/numbers）故意不在列——ASText 读不出真 iWork 包（探针实测），诚实降级。
    private static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx"]

    /// UTType 会误判成媒体的源码扩展名，必须在 conforms 之前按字面拦截：
    /// "ts" 解析成 public.mpeg-2-transport-stream、"mts" 同理 AVCHD——TypeScript 源码
    /// 会被 conforms(to:.movie) 判成视频（评审实证；本 app 的 F4 文本编辑白名单
    /// MainViewController.textExtensions 同样认 .ts 为文本，两处判定源必须一致）。
    /// 199 个常见源码/配置扩展名全扫（评审探针）：非文本命中只有这两个。
    private static let forcedTextExtensions: Set<String> = ["ts", "mts"]

    public static func classify(filenameExtension ext: String) -> PreviewKind {
        let e = ext.lowercased()
        if richTextExtensions.contains(e) { return .richText }
        if forcedTextExtensions.contains(e) { return .text }
        guard let type = UTType(filenameExtension: e) else { return .text }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }     // png/heic/svg/webp/gif…（含旧白名单漏的 heic）
        if type.conforms(to: .movie) || type.conforms(to: .audio) { return .media }
        return .text   // xlsx/pptx/iWork/html/未知/无扩展名：交文本路嗅探自证（坏=降级，诚实）
    }
}
