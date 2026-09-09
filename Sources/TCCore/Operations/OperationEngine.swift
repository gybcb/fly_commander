import Foundation

public final class OperationEngine {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    // MARK: - 按数据源分流（T3）
    // 同源（src.sourceID == dst.sourceID）：走源内快路径（本地 fm / SFTP 服务端 rename）。
    // 跨源：流式传输 src.openReader → dst.streamWrite（64KB 块）；
    //       跨源 move 成功后删源，删源失败不回滚（按取舍记 warn）。
    //
    // 进度/取消：
    // - progress = 文件级 (done, total)；byteProgress = **单文件内** (done, total) 字节数，
    //   仅跨源流式路径触发（同源 copyItem / exec cp 是服务器/文件系统黑盒，给不了字节）。
    // - cancel 的生效边界（有意分层，勿"优化"成即时中断）：
    //   本地/同源 = 文件边界；跨源 pump = 64KB 块边界；exec cp = 等当前文件 cp 自然完成
    //   （Traversio execute 无 abort API）。取消时已写出的残缺目标文件**不删**（维持现状）。

    public func performCopy(_ items: [FileItem], to destDir: TCPath,
                            srcSource: FileSource, dstSource: FileSource,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil,
                            byteProgress: ((Int64, Int64) -> Void)? = nil,
                            cancel: CancelFlag? = nil) throws {
        var overwriteAll = false, skipAll = false
        let total = items.count
        for (i, item) in items.enumerated() {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            let dst = destDir.joining(item.name)
            if try resolveConflict(item, dst, dstSource: dstSource,
                                   prompt: prompt,
                                   overwriteAll: &overwriteAll, skipAll: &skipAll) {
                progress?(i + 1, total); continue
            }
            if srcSource.sourceID == dstSource.sourceID {
                try dstSource.copyItem(from: item.path, to: dst)
            } else {
                try checkCrossSourceDirectory(item)
                try stream(from: srcSource, to: dstSource, src: item.path, dst: dst,
                           byteProgress: byteProgress, cancel: cancel)
            }
            progress?(i + 1, total)
        }
    }

    /// - Parameter onWarning: 跨源 move 删源失败的**结构化原料**（残留文件名 + 原始错误）。
    ///   成品警告句由调用方（持 L10n 的边界）组装；内核只产语义数据，零中文。
    public func performMove(_ items: [FileItem], to destDir: TCPath,
                            srcSource: FileSource, dstSource: FileSource,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil,
                            byteProgress: ((Int64, Int64) -> Void)? = nil,
                            cancel: CancelFlag? = nil,
                            onWarning: ((String, TCError) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        // 同源 move 失败需回滚已完成项；跨源 move 传输成功后不回滚（删源失败只记警告）。
        var rolledBack: [(from: TCPath, to: TCPath)] = []
        let sameSource = srcSource.sourceID == dstSource.sourceID
        let total = items.count
        for (i, item) in items.enumerated() {
            let dst = destDir.joining(item.name)
            do {
                // 取消检查放在 do **内**：抛 .cancelled 走下方 catch，回滚已完成的同源 move。
                if cancel?.isCancelled == true { throw TCError.cancelled }
                // 冲突判定放在 do 内：前置覆盖删除失败（如目标带不可变标志）
                // 同样要触发回滚，与本地旧路径语义一致。
                if try resolveConflict(item, dst, dstSource: dstSource,
                                       prompt: prompt,
                                       overwriteAll: &overwriteAll, skipAll: &skipAll) {
                    progress?(i + 1, total); continue
                }
                if sameSource {
                    try dstSource.moveItem(from: item.path, to: dst)
                    rolledBack.append((from: dst, to: item.path))
                } else {
                    try checkCrossSourceDirectory(item)
                    try stream(from: srcSource, to: dstSource, src: item.path, dst: dst,
                               byteProgress: byteProgress, cancel: cancel)
                    do { try srcSource.removeItem(at: item.path) }
                    catch { onWarning?(item.name, asTCError(error)) }
                }
            } catch {
                // 含 cancel 抛出的 .cancelled——统一走回滚路径（取消不裸 throw，
                // 否则已 move 的同源项滞留目标目录）。
                for pair in rolledBack.reversed() { try? dstSource.moveItem(from: pair.from, to: pair.to) }
                throw asTCError(error)
            }
            progress?(i + 1, total)
        }
    }

    public func performRename(_ item: FileItem, to newName: String, source: FileSource) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw TCError.invalidPath(newName) }
        guard let parent = item.path.parent else { throw TCError.invalidPath(item.path.pathString) }
        let dst = parent.joining(trimmed)
        if (try? source.stat(dst)) != nil { throw TCError.alreadyExists(trimmed) }
        try source.renameItem(at: item.path, to: dst)
    }

    @discardableResult
    public func performMakeDirectory(_ name: String, in dir: TCPath,
                                     source: FileSource) throws -> TCPath {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw TCError.invalidPath(name) }
        let newDir = dir.joining(trimmed)
        if (try? source.stat(newDir)) != nil { throw TCError.dirExists(trimmed) }
        try source.makeDirectory(at: newDir)
        return newDir
    }

    /// 直接删除（**不进废纸篓**）：远端无回收站，目录由 source.removeItem 递归删除。
    /// 逐个删、单项失败不中断整批（尽力删完），最后抛首个错误。
    public func performDelete(_ items: [FileItem], source: FileSource) throws {
        var firstError: TCError?
        for item in items {
            do {
                try source.removeItem(at: item.path)
            } catch {
                firstError = firstError ?? asTCError(error)
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: - 私有

    /// 跨源流式只支持文件：目录（openReader 无法读）此前被静默当空文件传过去。
    /// 明确报错（递归跨源复制另立项）。
    private func checkCrossSourceDirectory(_ item: FileItem) throws {
        if item.isDirectory {
            throw TCError.crossSourceDir(item.name)
        }
    }

    /// 冲突判定。返回 true 表示本项被跳过（skip/skipAll）。
    /// 其余分支已完成目标清理（overwrite/overwriteAll）或已 throw（cancel）。
    private func resolveConflict(_ item: FileItem, _ dst: TCPath, dstSource: FileSource,
                                 prompt: ConflictPrompt?,
                                 overwriteAll: inout Bool, skipAll: inout Bool) throws -> Bool {
        guard (try? dstSource.stat(dst)) != nil else { return false }
        if skipAll { return true }
        if overwriteAll { try dstSource.removeItem(at: dst); return false }
        guard let prompt else { try dstSource.removeItem(at: dst); return false }
        switch prompt(item.path, dst) {
        case .overwrite: try dstSource.removeItem(at: dst); return false
        case .overwriteAll: overwriteAll = true; try dstSource.removeItem(at: dst); return false
        case .skip: return true
        case .skipAll: skipAll = true; return true
        case .cancel: throw TCError.cancelled
        }
    }

    /// 跨源流式复制（64KB 块）。字节进度在 reader 闭包内累加（协议零改动）；
    /// totalBytes==0（stat 拿不到大小）**不报字节**——宁缺毋假（否则恒 100% 或除零）。
    /// 取消在块边界生效：抛 .cancelled 使 streamWrite 中止（其错误原样上抛，不静默截断）。
    private func stream(from srcSource: FileSource, to dstSource: FileSource,
                        src: TCPath, dst: TCPath,
                        byteProgress: ((Int64, Int64) -> Void)? = nil,
                        cancel: CancelFlag? = nil) throws {
        let totalBytes = Int64((try? srcSource.stat(src))?.size ?? 0)
        let reader = try srcSource.openReader(src)
        var transferred: Int64 = 0
        try dstSource.streamWrite(dst, totalBytes: totalBytes) {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            guard let chunk = try reader(64 * 1024) else { return Data() }   // 读失败沿闭包 throw 上抛
            transferred += Int64(chunk.count)
            if totalBytes > 0 { byteProgress?(transferred, totalBytes) }
            return chunk
        }
    }

    // MARK: - 无源参数旧签名（保留给既有测试/兼容调用；内部走本地源）

    public func performCopy(_ items: [FileItem], to destDir: TCPath,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws {
        let local = LocalFileSource()
        try performCopy(items, to: destDir, srcSource: local, dstSource: local,
                        prompt: prompt, progress: progress)
    }

    public func performMove(_ items: [FileItem], to destDir: TCPath,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws {
        let local = LocalFileSource()
        try performMove(items, to: destDir, srcSource: local, dstSource: local,
                        prompt: prompt, progress: progress)
    }
    public func performRename(_ item: FileItem, to newName: String) throws {
        try performRename(item, to: newName, source: LocalFileSource())
    }

    @discardableResult
    public func performMakeDirectory(_ name: String, in dir: TCPath) throws -> TCPath {
        try performMakeDirectory(name, in: dir, source: LocalFileSource())
    }
}
