import XCTest
@testable import TCCore

/// 同源拷贝的字节进度通道合同（同服务器 cp 黑盒回传进度的引擎侧一半）。
///
/// 背景：两窗格连同机 SFTP → sourceID 相等 → 引擎走 copyItem 快路径，
/// 该路从不报 byteProgress → 面板全程无字节帧（无进度条、无色点）。
/// 修复 = FileSource 新增带 byteProgress 的 copyItem 重载（协议默认实现
/// 转调旧方法），引擎同源分支改调重载。
final class SameSourceCopyProgressTests: XCTestCase {

    private func item(_ name: String, size: Int64 = 1000) -> FileItem {
        FileItem(id: name, path: TCPath("local:///\(name)"), name: name,
                 isDirectory: false, size: size, modificationDate: Date(timeIntervalSince1970: 0),
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    /// 实现了新重载的源：引擎必须把 byteProgress 透传到同源 copyItem。
    /// （修复前红：引擎只调旧 copyItem(from:to:)，overloadCalls 恒 0。）
    private final class ProgressReportingSource: FileSource {
        let sourceID = "fake://same"
        var plainCalls = 0
        var overloadCalls = 0
        func listDirectory(_ path: TCPath) throws -> [FileItem] { [] }
        func isDirectory(_ path: TCPath) -> Bool { false }
        func stat(_ path: TCPath) throws -> FileItem? { nil }
        func copyItem(from: TCPath, to: TCPath) throws { plainCalls += 1 }
        func copyItem(from: TCPath, to: TCPath,
                      byteProgress: ((Int64, Int64) -> Void)?) throws {
            overloadCalls += 1
            // 模拟 cp 黑盒执行中回传（含 total==0 不定量帧）。
            byteProgress?(0, 1000)
            byteProgress?(500, 1000)
            byteProgress?(1000, 1000)
            byteProgress?(0, 0)
        }
        func moveItem(from: TCPath, to: TCPath) throws {}
        func renameItem(at: TCPath, to: TCPath) throws {}
        func makeDirectory(at: TCPath) throws {}
        func removeItem(at: TCPath) throws {}
        func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
        func streamWrite(_ path: TCPath, totalBytes: Int64?,
                         write: @escaping () throws -> Data) throws {}
    }

    /// 只实现旧协议的源：默认实现转调 copyItem(from:to:)，既有后端零改动。
    private final class LegacySource: FileSource {
        let sourceID = "fake://legacy"
        var plainCalls = 0
        func listDirectory(_ path: TCPath) throws -> [FileItem] { [] }
        func isDirectory(_ path: TCPath) -> Bool { false }
        func stat(_ path: TCPath) throws -> FileItem? { nil }
        func copyItem(from: TCPath, to: TCPath) throws { plainCalls += 1 }
        func moveItem(from: TCPath, to: TCPath) throws {}
        func renameItem(at: TCPath, to: TCPath) throws {}
        func makeDirectory(at: TCPath) throws {}
        func removeItem(at: TCPath) throws {}
        func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
        func streamWrite(_ path: TCPath, totalBytes: Int64?,
                         write: @escaping () throws -> Data) throws {}
    }

    func testEngineForwardsByteProgressIntoSameSourceCopyItem() throws {
        let src = ProgressReportingSource()
        let engine = OperationEngine()
        var frames: [(Int64, Int64)] = []
        try engine.performCopy([item("a.bin")], to: TCPath("local:///dst"),
                               srcSource: src, dstSource: src,
                               byteProgress: { d, t in frames.append((d, t)) })
        XCTAssertEqual(src.overloadCalls, 1, "同源拷贝必须走带进度的 copyItem 重载")
        XCTAssertEqual(src.plainCalls, 0, "走了重载就不再走旧入口")
        XCTAssertEqual(frames.count, 4, "引擎不吞帧（面板节流不在引擎层）")
        // 同源路此前恒无字节帧 → 进度条缺席；这是本修复的鉴别力锁。
        XCTAssertFalse(frames.isEmpty,
                       "同源 copyItem 路必须把实现方回传的字节帧送到 byteProgress（修复前恒空 = 无进度条根因）")
    }

    func testLegacyConformanceFallsBackToPlainCopyItem() throws {
        let src = LegacySource()
        let engine = OperationEngine()
        try engine.performCopy([item("a.bin")], to: TCPath("local:///dst"),
                               srcSource: src, dstSource: src)
        XCTAssertEqual(src.plainCalls, 1, "未实现重载的既有源经协议默认实现仍走旧 copyItem")
    }

    /// 取消检查仍在条目边界：同条目帧转发不影响 cancel 语义。
    func testCancelStillHonoredAtEntryBoundary() throws {
        let src = ProgressReportingSource()
        let engine = OperationEngine()
        let cancel = CancelFlag()
        cancel.cancel()
        XCTAssertThrowsError(try engine.performCopy([item("a.bin")], to: TCPath("local:///d"),
                                                     srcSource: src, dstSource: src,
                                                     cancel: cancel)) { error in
            XCTAssertEqual(error as? TCError, .cancelled)
        }
        XCTAssertEqual(src.overloadCalls, 0)
    }
}
