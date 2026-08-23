import XCTest
import AppKit
@testable import FlyCommander

/// 预览有界读取（loadPreviewText）：截断/二进制嗅探/大小边界。
/// 背景：1.5MB 文件滚动慢 → 文本视图只装文件开头 512KB，超出走截断横幅。
final class PreviewTextLoadingTests: XCTestCase {
    private var base: URL!
    private let limit = 512 * 1024

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func file(_ name: String) -> URL { base.appendingPathComponent(name) }

    func testSmallFileReturnsWholeContent() throws {
        let url = file("small.txt")
        let content = String(repeating: "hello\n", count: 100)   // 600B
        try content.write(to: url, atomically: true, encoding: .utf8)
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        XCTAssertNotNil(pt)
        XCTAssertEqual(pt?.text, content)
        XCTAssertEqual(pt?.totalBytes, Int64(content.utf8.count))
        XCTAssertEqual(pt?.truncated, false)
    }

    /// 1.5MB 文件：只取开头 limit 字节，truncated = true，totalBytes = 全量。
    func testLargeFileIsTruncatedToLimit() throws {
        let url = file("big.txt")
        // 1_500_000 字节的 ASCII 内容（1 字符 = 1 字节，便于精确断言）
        let content = String(repeating: "abcde\n", count: 250_000)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        XCTAssertNotNil(pt)
        XCTAssertEqual(pt?.text.utf8.count, limit, "应恰好只读 limit 字节")
        XCTAssertEqual(pt?.totalBytes, 1_500_000)
        XCTAssertEqual(pt?.truncated, true)
        // 多行小行文件不应触发行截断
        XCTAssertEqual(pt?.longLineTruncated, false)
        // 取的是文件开头
        XCTAssertEqual(pt?.text, String(content.prefix(limit)))
    }

    func testBinaryHeadReturnsNil() throws {
        let url = file("bin.dat")
        var data = Data(repeating: 1, count: 1000)   // 0x01 全是控制字符 → 密度 100% → 二进制
        data[10] = 0
        try data.write(to: url)
        XCTAssertNil(PreviewViewController.loadPreviewText(url: url, limit: limit))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(PreviewViewController.loadPreviewText(url: file("nope.txt"), limit: limit))
    }

    func testEmptyFileIsEmptyTextNotBinary() throws {
        let url = file("empty.txt")
        try Data().write(to: url)
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        XCTAssertNotNil(pt)
        XCTAssertEqual(pt?.text, "")
        XCTAssertEqual(pt?.totalBytes, 0)
        XCTAssertEqual(pt?.truncated, false)
    }

    func testNulBeyondSniffWindowIsStillText() throws {
        // NUL 在 8KB 嗅探窗口之外 → 不判二进制（与原 8KB sniff 语义一致）
        let url = file("nul_late.txt")
        var data = Data(repeating: 65, count: 20_000)   // "A" x 20000
        data[9000] = 0
        try data.write(to: url)
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        XCTAssertNotNil(pt)
        XCTAssertEqual(pt?.truncated, false)
    }

    // MARK: - 二进制嗅探（控制字符密度）与 .torrent 强制文本

    func testIsProbablyTextPure() {
        XCTAssertTrue(PreviewViewController.isProbablyText(Data()))
        XCTAssertTrue(PreviewViewController.isProbablyText(Data("hello world\n".utf8)))
        // 8KB 里只有 1 个 NUL（密度 << 2%）→ 文本（旧"含 NUL 即二进制"会误判）
        var oneNul = Data(repeating: 65, count: 8192)
        oneNul[100] = 0
        XCTAssertTrue(PreviewViewController.isProbablyText(oneNul))
        // 全控制字符 → 二进制
        XCTAssertFalse(PreviewViewController.isProbablyText(Data(repeating: 1, count: 100)))
        // 恰好 2%：8192 * 0.02 = 163.84 → 163 个控制字符通过，164 个拒绝
        var at = Data(repeating: 65, count: 8192)
        for i in 0..<163 { at[i] = 0 }
        XCTAssertTrue(PreviewViewController.isProbablyText(at))
        at[163] = 0
        XCTAssertFalse(PreviewViewController.isProbablyText(at))
    }

    /// 稀疏 NUL 的普通文本文件 → 文本（回归：旧语义把任何 NUL 都判二进制）。
    func testSparseNulFileIsText() throws {
        let url = file("sparse_nul.txt")
        var data = Data(repeating: 72, count: 4096)   // "h" x 4096
        data[500] = 0
        data[3000] = 1   // 两个控制字符，密度 ~0.05%
        try data.write(to: url)
        XCTAssertNotNil(PreviewViewController.loadPreviewText(url: url, limit: limit))
    }

    /// .torrent（bencode 文本 + piece 哈希）：哈希控制字节能占前 8KB 的 ~50%，
    /// 密度嗅探会误判 → forceTextExtensions 白名单跳过嗅探按文本预览。
    func testTorrentIsForceTextEvenWithDenseHashBytes() throws {
        let url = file("small.torrent")
        var data = Data()
        data.append(Data("d8:announce40:https://tracker.example/ann13:created by10:Handmade3:inf".utf8))
        data.append(Data("4:name8:movie.mkv6:length123456".utf8))
        data.append(Data("11:piece length1310726:pieces".utf8))
        data.append(Data(repeating: 7, count: 40))   // 模拟 40 字节 piece 哈希（含高位字节）
        data.append(Data("ee".utf8))
        try data.write(to: url)
        XCTAssertFalse(PreviewViewController.isProbablyText(data.prefix(8192)), "前置：模拟数据应触发二进制判定")
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        XCTAssertNotNil(pt, ".torrent 应按文本预览（跳过二进制嗅探）")
        XCTAssertEqual(pt?.text.hasPrefix("d8:announce"), true, "bencode 可读部分应原样显示")
        XCTAssertEqual(pt?.truncated, false)
    }

    /// 非白名单扩展名的同形状数据仍判二进制（白名单只放行 .torrent）。
    func testNonTorrentDenseFileStillBinary() throws {
        let url = file("dense.bin")
        var data = Data("d8:announce40:https://tracker.example/ann".utf8)
        data.append(Data(repeating: 7, count: 4096))   // 大段控制字符 → 密度 >> 2%
        try data.write(to: url)
        XCTAssertNil(PreviewViewController.loadPreviewText(url: url, limit: limit))
    }

    // MARK: - 单行截断（大单行文件预览空白的根治：TextKit 排版量随单行字符数走）

    /// 100KB 单行（无换行）：行截到 textLineLimit + 标记，字节未超限故 truncated=false。
    func testSingleLongLineIsTruncatedToLineLimit() throws {
        let url = file("oneline.txt")
        try String(repeating: "a", count: 100_000).write(to: url, atomically: true, encoding: .utf8)
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        let lineLimit = PreviewViewController.textLineLimit
        let marker = PreviewViewController.longLineMarker
        XCTAssertEqual(pt?.text, String(repeating: "a", count: lineLimit) + marker)
        XCTAssertEqual(pt?.longLineTruncated, true)
        XCTAssertEqual(pt?.truncated, false)
        XCTAssertEqual(pt?.totalBytes, Int64(100_000))
    }

    /// 混合：短行原样保留，只有超长行被截断。
    func testMixedLinesOnlyLongOnesTruncated() throws {
        let url = file("mixed.txt")
        let long = String(repeating: "b", count: 40_000)
        try ("short\n" + long).write(to: url, atomically: true, encoding: .utf8)
        let pt = PreviewViewController.loadPreviewText(url: url, limit: limit)
        let lineLimit = PreviewViewController.textLineLimit
        XCTAssertEqual(pt?.text, "short\n" + String(repeating: "b", count: lineLimit)
            + PreviewViewController.longLineMarker)
        XCTAssertEqual(pt?.longLineTruncated, true)
        XCTAssertEqual(pt?.truncated, false)
    }

    /// 多行文件无超长行 → 文本逐字节不变（含尾换行），标志为 false。
    func testTruncateLongLinesIdentityForShortLines() {
        let raw = "line1\nline2\n"
        let (text, truncated) = PreviewViewController.truncateLongLines(raw)
        XCTAssertEqual(text, raw)
        XCTAssertEqual(truncated, false)
    }

    /// 恰好等于上限的行不截断（严格 >）。
    func testTruncateLongLinesExactlyLimitNotTruncated() {
        let line = String(repeating: "c", count: PreviewViewController.textLineLimit)
        let (text, truncated) = PreviewViewController.truncateLongLines(line + "\n")
        XCTAssertEqual(text, line + "\n")
        XCTAssertEqual(truncated, false)
    }

    func testTruncateLongLinesEmpty() {
        let (text, truncated) = PreviewViewController.truncateLongLines("")
        XCTAssertEqual(text, "")
        XCTAssertEqual(truncated, false)
    }
}
