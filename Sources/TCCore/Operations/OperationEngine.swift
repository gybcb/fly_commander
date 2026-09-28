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
        let cross = srcSource.sourceID != dstSource.sourceID
        for (i, item) in items.enumerated() {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            let dst = destDir.joining(item.name)
            if cross, item.isDirectory {
                // 目录冲突走 copyDirectoryCross 的**合并**语义——绝不进 resolveConflict
                // （其 overwrite 分支 removeItem 会删掉整棵目标目录树，灾难级）。
                try copyDirectoryCross(item, to: dst, srcSource: srcSource, dstSource: dstSource,
                                       prompt: prompt, overwriteAll: &overwriteAll,
                                       skipAll: &skipAll, byteProgress: byteProgress, cancel: cancel)
            } else {
                if try resolveConflict(item, dst, dstSource: dstSource,
                                       prompt: prompt,
                                       overwriteAll: &overwriteAll, skipAll: &skipAll) {
                    progress?(i + 1, total); continue
                }
                if cross {
                    try stream(from: srcSource, to: dstSource, src: item.path, dst: dst,
                               byteProgress: byteProgress, cancel: cancel)
                } else {
                    try dstSource.copyItem(from: item.path, to: dst)
                }
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
                if !sameSource, item.isDirectory {
                    // 目录：合并语义递归泵（不进 resolveConflict——其 overwrite 删目标树），
                    // 整体传完后删源根一次（源 removeItem 各实现皆递归）。
                    // 返回 true=整目录被 skip → 没传任何东西，**不得删源**。
                    let skipped = try copyDirectoryCross(item, to: dst, srcSource: srcSource, dstSource: dstSource,
                                                         prompt: prompt, overwriteAll: &overwriteAll,
                                                         skipAll: &skipAll, byteProgress: byteProgress, cancel: cancel)
                    if !skipped {
                        do { try srcSource.removeItem(at: item.path) }
                        catch { onWarning?(item.name, asTCError(error)) }
                    }
                } else {
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
                        try stream(from: srcSource, to: dstSource, src: item.path, dst: dst,
                                   byteProgress: byteProgress, cancel: cancel)
                        do { try srcSource.removeItem(at: item.path) }
                        catch { onWarning?(item.name, asTCError(error)) }
                    }
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

    /// 跨源目录递归复制（用户 issue：单文件可用、目录不可用——旧硬闸 `checkCrossSourceDirectory`
    /// 只抛"暂不支持"，本实现取代它；本地⇄SFTP 与 SFTP⇄SFTP 同修）。
    /// 语义合同（各有锁，见 OperationEngineRoutingTests）：
    /// - 目标无同名 → 逐级 makeDirectory（含空目录）+ 文件逐个走既有 64KB `stream` 泵；
    /// - 目标已有同名**目录** → **合并**：询问一次；overwrite=合并不删目标树
    ///   （目录走 resolveConflict 的 overwrite 会 removeItem 删整棵树——灾难，故不走它）；
    ///   skip=整目录跳过（返回 true，调用方据此不删源）；cancel=抛；
    /// - 目标同名但是**文件** → 回退普通冲突语义（删文件建目录）；
    /// - 目录**内部**文件冲突 = 逐文件 resolveConflict（与顶层同款，含覆盖删除）；
    /// - 取消在文件/子目录边界生效（抛 .cancelled，与整批合同一致）；
    /// - 进度不动语义：整个目录对上算 1 个条目（计数在调用方），字节进度逐文件转发。
    /// - returns: true = 整个目录被跳过（skip/skipAll）——move 调用方据此不删源。
    @discardableResult
    private func copyDirectoryCross(_ item: FileItem, to dst: TCPath,
                                    srcSource: FileSource, dstSource: FileSource,
                                    prompt: ConflictPrompt?,
                                    overwriteAll: inout Bool, skipAll: inout Bool,
                                    byteProgress: ((Int64, Int64) -> Void)?,
                                    cancel: CancelFlag?) throws -> Bool {
        if cancel?.isCancelled == true { throw TCError.cancelled }
        let existing = try? dstSource.stat(dst)
        if existing != nil {
            if skipAll { return true }
            if !overwriteAll {
                if existing?.isDirectory == true {
                    // 目录冲突=合并（overwrite 分支**不删**目标树——与文件语义的分岔点）。
                    // 无提示器（纯内核环境）→ 缺省合并（与文件冲突的"缺省覆盖"同向）。
                    if let prompt {
                        switch prompt(item.path, dst) {
                        case .overwrite: break
                        case .overwriteAll: overwriteAll = true
                        case .skip: return true
                        case .skipAll: skipAll = true; return true
                        case .cancel: throw TCError.cancelled
                        }
                    }
                } else {
                    // 同名文件挡路：普通冲突语义（overwrite=删文件后建目录）
                    if try resolveConflict(item, dst, dstSource: dstSource, prompt: prompt,
                                           overwriteAll: &overwriteAll, skipAll: &skipAll) {
                        return true
                    }
                }
            }
        }
        // 目标目录就位（幂等：已存在=合并进去不重建；挡路文件已被 resolveConflict 删除→建目录）
        if existing == nil || existing?.isDirectory == false {
            try dstSource.makeDirectory(at: dst)
        }
        try copyDirectoryContents(from: item.path, to: dst, srcSource: srcSource,
                                  dstSource: dstSource, prompt: prompt,
                                  overwriteAll: &overwriteAll, skipAll: &skipAll,
                                  byteProgress: byteProgress, cancel: cancel)
        return false
    }

    /// 目录内容泵（递归体）：列源 → 文件 stream / 子目录递归（合并式，不再询问）。
    private func copyDirectoryContents(from srcDir: TCPath, to dstDir: TCPath,
                                       srcSource: FileSource, dstSource: FileSource,
                                       prompt: ConflictPrompt?,
                                       overwriteAll: inout Bool, skipAll: inout Bool,
                                       byteProgress: ((Int64, Int64) -> Void)?,
                                       cancel: CancelFlag?) throws {
        let children = try srcSource.listDirectory(srcDir)
        for child in children {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            let childDst = dstDir.joining(child.name)
            if child.isDirectory {
                // 嵌套目录不再询问（顶层那一次"合并"授权覆盖整棵树）；skipAll 置位则整支停止。
                if skipAll { return }
                let existed = (try? dstSource.stat(childDst))?.isDirectory ?? false
                if !existed { try dstSource.makeDirectory(at: childDst) }
                try copyDirectoryContents(from: child.path, to: childDst, srcSource: srcSource,
                                          dstSource: dstSource, prompt: prompt,
                                          overwriteAll: &overwriteAll, skipAll: &skipAll,
                                          byteProgress: byteProgress, cancel: cancel)
            } else {
                if try resolveConflict(child, childDst, dstSource: dstSource, prompt: prompt,
                                       overwriteAll: &overwriteAll, skipAll: &skipAll) {
                    continue
                }
                try stream(from: srcSource, to: dstSource, src: child.path, dst: childDst,
                           byteProgress: byteProgress, cancel: cancel)
            }
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
