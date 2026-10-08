import Foundation

public final class OperationEngine {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    /// 跨机直传接缝（App 层注入；nil = 永远 pump）。粒度 = 顶层条目：
    /// `.handled` 时**整条（含整棵目录树）已由实现方完成**，引擎不得再递归；
    /// `.unavailable` 时**未传输任何字节**，引擎从干净状态走 pump。
    /// 启用条件（两端皆 sftp 且不同服务器）由注入方自查，引擎不看 source 类型。
    /// 契约：后台线程调用；抛错 = 传输失败（不回退）；byteProgress 第二参 0 = 总量未知。
    public var directCrossTransfer: (
        (_ item: FileItem, _ destDir: TCPath, _ byteProgress: ((Int64, Int64) -> Void)?) throws -> DirectOutcome
    )?

    // MARK: - 按数据源分流（T3）
    // 同源（src.sourceID == dst.sourceID）：走源内快路径（本地 fm / SFTP 服务端 rename）。
    // 跨源：流式传输 src.openReader → dst.streamWrite（64KB 块）；
    //       跨源 move 成功后删源，删源失败不回滚（按取舍记 warn）。
    //
    // 进度/取消：
    // - progress = 文件级 (done, total)；byteProgress = **单文件内** (done, total) 字节数。
    //   跨源流式路径由引擎直接上报；同源路由 copyItem(from:to:byteProgress:) 重载
    //   **自愿回传**（同机 SFTP cp = 连接层 stat 轮询；本地 FileManager 给不了字节 =
    //   默认实现转调旧签名，无帧 = 维持旧行为）。合同同 pump：done 单调、
    //   total==0 未知、末帧 done==total。
    // - 目录合并语义（copyDirectoryCross）条内逐文件的字节帧对调用方（TransferEngine
    //   面板显示最后帧）不可见 → 目录整体完成后补一帧 (lastTotal, lastTotal) 把面板
    //   百分比拉回真实值；不补则残留目录前最后一文件的 ~2% 直到操作结束。
    //   合并帧的 done 用**该文件自身** total 而非累加——累加值对 per-file total 无意义。
    // - cancel 的生效边界（有意分层，勿"优化"成即时中断）：
    //   本地/同源 = 文件边界；跨源 pump = 64KB 块边界；exec cp = 等当前文件 cp 自然完成
    //   （Traversio execute 无 abort API）。取消时已写出的残缺目标文件**不删**（维持现状）。

    /// - Parameter aggregate: **整批全进度**旁路通道 (整批累计已传字节, 预扫描总量)。
    ///   与 byteProgress（单文件合同，终审 B2 禁区）互不干扰：跨条目基线集中在
    ///   此账本折算（合同见文件头「聚合账本」注）。nil = 零聚合帧 = 既有调用方
    ///   行为一字不动（且**不做预扫描**，零 list 成本）。
    public func performCopy(_ items: [FileItem], to destDir: TCPath,
                            srcSource: FileSource, dstSource: FileSource,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil,
                            byteProgress: ((Int64, Int64) -> Void)? = nil,
                            cancel: CancelFlag? = nil,
                            aggregate: ((Int64, Int64) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        var lastTotals: (done: Int64, total: Int64)?
        // 直传粘连：整批只问一次，`.unavailable` 后同批不再问（失败原因在批量级别不会自愈）。
        var directFailed = false
        let total = items.count
        let cross = srcSource.sourceID != dstSource.sourceID
        let ledger = makeLedger(items, source: srcSource, cancel: cancel, aggregate: aggregate)
        for (i, item) in items.enumerated() {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            let dst = destDir.joining(item.name)
            ledger?.beginEntry(at: i)
            if cross, item.isDirectory {
                // 守卫：目标**任何同名在位**（目录=合并语义、文件=覆盖冲突）→ 接缝零调用，
                // 全部交 copyDirectoryCross 既有语义判定（rsync 表达不了合并/冲突提示）。
                // 只 stat 不弹提示：守卫若弹提示，copyDirectoryCross 会弹第二次（双弹窗回归）。
                let destExists = directCrossTransfer != nil && !directFailed
                    && (try? dstSource.stat(dst)) != nil
                if !destExists, directCrossTransfer != nil, !directFailed {
                    switch try askDirect(item, dst, byteProgress: byteProgress, ledger: ledger) {
                    case .handled:
                        ledger?.endEntry()
                        progress?(i + 1, total)
                        continue                                   // 整树已完成，引擎不递归
                    case .unavailable: directFailed = true          // sticky
                    }
                }
                // 目录冲突走 copyDirectoryCross 的**合并**语义——绝不进 resolveConflict
                // （其 overwrite 分支 removeItem 会删掉整棵目标目录树，灾难级）。
                let bytesBefore = lastTotals?.total
                _ = try copyDirectoryCross(item, to: dst, srcSource: srcSource, dstSource: dstSource,
                                           prompt: prompt, overwriteAll: &overwriteAll,
                                           skipAll: &skipAll, byteProgress: byteProgress, cancel: cancel,
                                           lastTotals: &lastTotals, ledger: ledger)
                mergeDirectoryProgress(byteProgress, lastTotals: &lastTotals, bytesBefore: bytesBefore)
            } else {
                if try resolveConflict(item, dst, dstSource: dstSource,
                                       prompt: prompt,
                                       overwriteAll: &overwriteAll, skipAll: &skipAll) {
                    ledger?.endEntry()                             // 跳过按计划量推账
                    progress?(i + 1, total); continue
                }
                if cross {
                    // 文件：resolveConflict 已保证目标干净（不存在或覆盖已删）→ 可问接缝。
                    if directCrossTransfer != nil, !directFailed,
                       case .handled = try askDirect(item, dst, byteProgress: byteProgress, ledger: ledger) {
                        ledger?.endEntry()
                        progress?(i + 1, total)
                        continue
                    } else if directCrossTransfer != nil { directFailed = true }
                    try stream(from: srcSource, to: dstSource, src: item.path, dst: dst,
                               byteProgress: byteProgress, cancel: cancel, lastTotals: &lastTotals,
                               blockProgress: ledgerPump(ledger))
                } else {
                    try dstSource.copyItem(from: item.path, to: dst,
                                           byteProgress: ledgerEntryCumulative(byteProgress, ledger))
                }
            }
            ledger?.endEntry()
            progress?(i + 1, total)
        }
        ledger?.finish()
    }

    /// - Parameter onWarning: 跨源 move 删源失败的**结构化原料**（残留文件名 + 原始错误）。
    ///   成品警告句由调用方（持 L10n 的边界）组装；内核只产语义数据，零中文。
    /// - Parameter aggregate: 整批全进度旁路通道（合同同 performCopy，见文件头注）。
    public func performMove(_ items: [FileItem], to destDir: TCPath,
                            srcSource: FileSource, dstSource: FileSource,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil,
                            byteProgress: ((Int64, Int64) -> Void)? = nil,
                            cancel: CancelFlag? = nil,
                            onWarning: ((String, TCError) -> Void)? = nil,
                            aggregate: ((Int64, Int64) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        // 同源 move 失败需回滚已完成项；跨源 move 传输成功后不回滚（删源失败只记警告）。
        var rolledBack: [(from: TCPath, to: TCPath)] = []
        var lastTotals: (done: Int64, total: Int64)?
        // 直传粘连（语义同 performCopy）。
        var directFailed = false
        let sameSource = srcSource.sourceID == dstSource.sourceID
        let total = items.count
        let ledger = makeLedger(items, source: srcSource, cancel: cancel, aggregate: aggregate)
        for (i, item) in items.enumerated() {
            let dst = destDir.joining(item.name)
            do {
                // 取消检查放在 do **内**：抛 .cancelled 走下方 catch，回滚已完成的同源 move。
                if cancel?.isCancelled == true { throw TCError.cancelled }
                ledger?.beginEntry(at: i)
                if !sameSource, item.isDirectory {
                    // 守卫：目标**任何同名在位**（目录=合并语义、文件=覆盖冲突）→ 接缝零调用，
                    // 全部交 copyDirectoryCross 既有语义判定（只 stat 不弹，弹提示会与
                    // copyDirectoryCross 的提示叠成双弹窗）。
                    let destExists = directCrossTransfer != nil && !directFailed
                        && (try? dstSource.stat(dst)) != nil
                    if !destExists, directCrossTransfer != nil, !directFailed {
                        switch try askDirect(item, dst, byteProgress: byteProgress, ledger: ledger) {
                        case .handled:
                            // 整树已由接缝完成 → 删源根一次（递归删是各源 removeItem 的合同）。
                            do { try srcSource.removeItem(at: item.path) }
                            catch { onWarning?(item.name, asTCError(error)) }
                            ledger?.endEntry()
                            progress?(i + 1, total)
                            continue
                        case .unavailable: directFailed = true      // sticky → 落原合并路
                        }
                    }
                    // 目录：合并语义递归泵（不进 resolveConflict——其 overwrite 删目标树），
                    // 整体传完后删源根一次（源 removeItem 各实现皆递归）。
                    // 返回 true=整目录被 skip → 没传任何东西，**不得删源**。
                    let bytesBefore = lastTotals?.total
                    let skipped = try copyDirectoryCross(item, to: dst, srcSource: srcSource, dstSource: dstSource,
                                                         prompt: prompt, overwriteAll: &overwriteAll,
                                                         skipAll: &skipAll, byteProgress: byteProgress, cancel: cancel,
                                                         lastTotals: &lastTotals, ledger: ledger)
                    // 目录整体=1 条目（计数在调用方），条内逐文件字节帧对面板不可见 →
                    // 合并帧拉回真实百分比（合同见 performCopy 头部注释）。零写入不合并。
                    if !skipped { mergeDirectoryProgress(byteProgress, lastTotals: &lastTotals, bytesBefore: bytesBefore) }
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
                        ledger?.endEntry()                         // 跳过按计划量推账
                        progress?(i + 1, total); continue
                    }
                    if sameSource {
                        try dstSource.moveItem(from: item.path, to: dst)
                        rolledBack.append((from: dst, to: item.path))
                    } else {
                        // 跨源文件：resolveConflict 已保证目标干净 → 可问接缝。
                        // 接缝抛错进本 do 的 catch：rolledBack 在跨源路从不 append（回滚为空），
                        // throw asTCError 原样上抛——与 pump 抛错同路。
                        if directCrossTransfer != nil, !directFailed,
                           case .handled = try askDirect(item, dst, byteProgress: byteProgress, ledger: ledger) {
                            do { try srcSource.removeItem(at: item.path) }
                            catch { onWarning?(item.name, asTCError(error)) }
                            ledger?.endEntry()
                            progress?(i + 1, total)
                            continue
                        } else if directCrossTransfer != nil { directFailed = true }
                        try stream(from: srcSource, to: dstSource, src: item.path, dst: dst,
                                   byteProgress: byteProgress, cancel: cancel, lastTotals: &lastTotals,
                                   blockProgress: ledgerPump(ledger))
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
            ledger?.endEntry()
            progress?(i + 1, total)
        }
        ledger?.finish()
    }

    // MARK: - 聚合账本（全进度旁路通道）

    /// 聚合帧合同（用户批准的设计，spec
    /// docs/superpowers/specs/2026-10-08-directory-overall-transfer-progress-design.md）：
    /// - 总量 = 传输前**预扫描**（递归列源求字节和）。任何 list/stat 失败、深度/条目
    ///   超预算、扫描中被取消 → totalBytes=nil → **全程零聚合帧**（宁缺毋假，传输照常）。
    /// - 账本 `cumulative` = 已完成条目的**计划字节**和（计划外溢出丢弃——账本为准）。
    /// - 条内帧 = cumulative + 观测值（钳 [cumulative, planTotal]）；跨条目基线只在
    ///   此集中折算，**不违** :askDirect 注「单文件帧里不偷加」（终审 B2）。
    /// - skip/skipAll/接缝短路 → endEntry 按计划量推账（否则进度条卡死）。
    /// - 末帧 `finish()` 拉满 (planTotal, planTotal)。
    ///
    /// 计划量 = 文件 size / 目录树和 / 同源 cp 条目 size（cp 黑盒条内观测经
    /// copyItem(byteProgress:) 帧换算）。同源条目 size 未知（=0）→ 总量未知（宁缺毋假）。
    private final class AggregateLedger {
        let planTotal: Int64
        private let planned: [Int64]         // 与 items 等长（顶层条目计划字节）
        private let aggregate: (Int64, Int64) -> Void
        private var cumulative: Int64 = 0    // 已完成条目的计划字节和
        private var baseline: Int64 = 0      // 当前条目开始时的 cumulative
        private var index: Int = 0           // 当前条目下标（endEntry 后 +1）
        private var lastReported: Int64 = 0  // 单调钳

        init(planTotal: Int64, planned: [Int64], aggregate: @escaping (Int64, Int64) -> Void) {
            self.planTotal = planTotal
            self.planned = planned
            self.aggregate = aggregate
        }
        private var pumpFilePrev: Int64 = 0     // 目录泵：上一文件的文件内累计
        private var pumpEntryObs: Int64 = 0     // 目录泵：本条目累计观测（跨文件求和）

        /// 条目开始：基线 = 当前账（begin/end 严格成对，主循环单线程驱动）。
        func beginEntry(at i: Int) {
            index = i
            baseline = cumulative
            pumpFilePrev = 0
            pumpEntryObs = 0
        }
        /// 条目完成（含跳过/接缝短路）→ 按计划量推账（溢出丢：账本为准）。
        func endEntry() {
            cumulative += index < planned.count ? planned[index] : 0
            emit(cumulative)
        }
        /// 条内观测帧（done = 条目内**累计**观测）。钳 [baseline, min(baseline+计划, planTotal)]。
        func intraEntryFrame(_ done: Int64) {
            let plan = index < planned.count ? planned[index] : 0
            let upper = min(baseline + plan, planTotal)
            emit(max(baseline, min(upper, baseline + max(0, done))))
        }
        /// 新文件开始（pump 路每次 stream 调用 = 一个文件）：上一文件终值并入条目累计。
        func beginPumpFile() {
            pumpEntryObs += pumpFilePrev
            pumpFilePrev = 0
        }
        /// pump 路观测（done = **当前文件内**累计）→ 条目内累计 = 已完成文件和 + 本文件 done。
        func pumpFileFrame(_ done: Int64) {
            pumpFilePrev = max(pumpFilePrev, done)
            intraEntryFrame(pumpEntryObs + pumpFilePrev)
        }
        /// 全部条目走完 → 强制收口 (planTotal, planTotal)。
        func finish() {
            cumulative = planTotal
            emit(planTotal)
        }
        private func emit(_ done: Int64) {
            let v = max(lastReported, min(planTotal, done))
            lastReported = v
            aggregate(v, planTotal)
        }
    }

    /// 聚合预算（spec §3.1）：深度 24 / 条目 5000。超限 = 总量未知。
    static let planMaxDepth = 24
    static let planMaxEntries = 5000

    /// 预扫描 + 建账。aggregate=nil → nil（零扫描成本 = 既有调用方零回归）。
    /// 任一失败路（list 抛 / stat 抛 / 预算超 / 取消）→ nil（不发聚合帧，传输照常）。
    private func makeLedger(_ items: [FileItem], source: FileSource,
                            cancel: CancelFlag?,
                            aggregate: ((Int64, Int64) -> Void)?) -> AggregateLedger? {
        guard let aggregate, !items.isEmpty else { return nil }
        var planned: [Int64] = []
        var entries = 0
        var total: Int64 = 0
        for item in items {
            if cancel?.isCancelled == true { return nil }
            let bytes: Int64
            if item.isDirectory {
                guard let sum = planTreeBytes(item.path, source: source, depth: 0,
                                              entries: &entries, cancel: cancel) else { return nil }
                bytes = sum
            } else {
                bytes = max(0, item.size)
            }
            planned.append(bytes)
            total += bytes
        }
        guard total > 0 else { return nil }        // 全零 = 无字节可传 → 无聚合语义
        return AggregateLedger(planTotal: total, planned: planned, aggregate: aggregate)
    }

    /// 目录树字节和（递归 list）。预算超限 / 取消 / list 或 stat 抛 → nil。
    private func planTreeBytes(_ dir: TCPath, source: FileSource, depth: Int,
                               entries: inout Int, cancel: CancelFlag?) -> Int64? {
        guard depth < Self.planMaxDepth else { return nil }
        if cancel?.isCancelled == true { return nil }
        guard let children = try? source.listDirectory(dir) else { return nil }
        var sum: Int64 = 0
        for child in children {
            entries += 1
            guard entries <= Self.planMaxEntries else { return nil }
            if child.isDirectory {
                guard let sub = planTreeBytes(child.path, source: source, depth: depth + 1,
                                              entries: &entries, cancel: cancel) else { return nil }
                sum += sub
            } else {
                sum += max(0, child.size)
            }
        }
        return sum
    }

    /// pump 路（stream 块帧 = **文件内**累计）→ 账本观测包装。
    /// 目录条目含多文件：账本做「跨文件求和」换算（见 perFileFrame）。
    /// 账本 nil → nil（既有调用方零开销；byteProgress 由 stream 另路原样报）。
    private func ledgerPump(_ ledger: AggregateLedger?) -> ((Int64, Int64) -> Void)? {
        guard let ledger else { return nil }
        ledger.beginPumpFile()          // 闭包每次 stream 调用新建 = 显式文件边界
        return { done, _ in ledger.pumpFileFrame(done) }
    }

    /// 条目内**累计**观测路（同源 cp 轮询帧 / 直传接缝自报帧：done 已是本条目累计）
    /// → 账本基线折算。byteProgress 原样透传（单文件合同不动）。
    private func ledgerEntryCumulative(_ byteProgress: ((Int64, Int64) -> Void)?,
                                       _ ledger: AggregateLedger?) -> ((Int64, Int64) -> Void)? {
        guard ledger != nil || byteProgress != nil else { return nil }
        return { done, total in
            byteProgress?(done, total)
            ledger?.intraEntryFrame(done)
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
                                    cancel: CancelFlag?,
                                    lastTotals: inout (done: Int64, total: Int64)?,
                                    ledger: AggregateLedger?) throws -> Bool {
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
                                  byteProgress: byteProgress, cancel: cancel, lastTotals: &lastTotals,
                                  ledger: ledger)
        return false
    }

    /// 目录内容泵（递归体）：列源 → 文件 stream / 子目录递归（合并式，不再询问）。
    private func copyDirectoryContents(from srcDir: TCPath, to dstDir: TCPath,
                                       srcSource: FileSource, dstSource: FileSource,
                                       prompt: ConflictPrompt?,
                                       overwriteAll: inout Bool, skipAll: inout Bool,
                                       byteProgress: ((Int64, Int64) -> Void)?,
                                       cancel: CancelFlag?,
                                       lastTotals: inout (done: Int64, total: Int64)?,
                                       ledger: AggregateLedger?) throws {
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
                                          byteProgress: byteProgress, cancel: cancel, lastTotals: &lastTotals,
                                          ledger: ledger)
            } else {
                if try resolveConflict(child, childDst, dstSource: dstSource, prompt: prompt,
                                       overwriteAll: &overwriteAll, skipAll: &skipAll) {
                    continue
                }
                try stream(from: srcSource, to: dstSource, src: child.path, dst: childDst,
                           byteProgress: byteProgress, cancel: cancel, lastTotals: &lastTotals,
                           blockProgress: ledgerPump(ledger))
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

    /// 问接缝，字节帧**逐条目原样透传**（spec §1：(本条目已传, 本条目总量)，
    /// 0=未知——与 pump 的单文件语义逐字一致，终审 B2 裁定）。
    /// 旧实现把已完成条目字节做基线加进帧里（跨条目累计），与接缝实现自报的
    /// **当前文件** total 分母错配 → done>total 稳态、面板恒 100%。跨条目总量
    /// 若将来要做，必须连全部 pump 路一起重设（carry），不在帧里偷加。
    /// `.handled` 且最后一帧未满（含一帧未报）→ 引擎补一帧拉满，否则面板百分比残留
    /// 在中间态（与 mergeDirectoryProgress 同合同、同触发形：done != total 才补；
    /// total=0 的不定量帧恒不补）。
    private func askDirect(_ item: FileItem, _ dst: TCPath,
                           byteProgress: ((Int64, Int64) -> Void)?,
                           ledger: AggregateLedger? = nil) throws -> DirectOutcome {
        guard let seam = directCrossTransfer else { return .unavailable("no seam") }
        let last = LastFrame()                     // 逃逸闭包不能捕获局部 var → 装箱
        let wrapped: ((Int64, Int64) -> Void)? = ledgerEntryCumulative(byteProgress, ledger).map { agg in
            { done, total in
                last.raw = (done, total)
                agg(done, total)                   // 逐条目合同：不加工，原样透传（聚合走账本）
            }
        }
        let outcome = try seam(item, dst, wrapped)
        // 一帧未报（raw==nil）或有帧但未满（且定量）→ 补拉满帧（`(nil)?.done !=
        // (nil)?.total` 为 false，nil 须显式短路）。
        if case .handled(let bytes) = outcome, bytes > 0,
           last.raw == nil || (last.raw!.0 != last.raw!.1 && last.raw!.1 > 0) {
            wrapped?(bytes, bytes)
        }
        return outcome
    }

    /// 接缝最后一帧（原始未累计值）的装箱（供 askDirect 的逃逸闭包使用）。
    private final class LastFrame { var raw: (done: Int64, total: Int64)? }

    /// 跨源流式复制（256KB 块，SFTP 侧走读写双向流水线；见 SFTPClient.PrefetchReader/WriteWindow）。
    /// 字节进度在 reader 闭包内累加（协议零改动）；
    /// totalBytes==0（stat 拿不到大小）**不报字节**——宁缺毋假（否则恒 100% 或除零）。
    /// lastTotals（可选）记录本文件最后一帧 (transferred, totalBytes)——目录合并路
    /// 靠它在整目录完成后补合并帧（见 performCopy 头部注释）。
    /// 取消在块边界生效：抛 .cancelled 使 streamWrite 中止（其错误原样上抛，不静默截断）。
    private func stream(from srcSource: FileSource, to dstSource: FileSource,
                        src: TCPath, dst: TCPath,
                        byteProgress: ((Int64, Int64) -> Void)? = nil,
                        cancel: CancelFlag? = nil,
                        lastTotals: inout (done: Int64, total: Int64)?,
                        blockProgress: ((Int64, Int64) -> Void)? = nil) throws {
        let totalBytes = Int64((try? srcSource.stat(src))?.size ?? 0)
        let reader = try srcSource.openReader(src)
        var transferred: Int64 = 0
        try dstSource.streamWrite(dst, totalBytes: totalBytes) {
            if cancel?.isCancelled == true { throw TCError.cancelled }
            // 块大小 = SFTPTransfer.chunkSize（app 层 256KB，SFTP 包上限）。TCCore 零
            // import app 层 → 字面量镜像，两处必须同改（PipelinedTransferTests 锁合同）。
            guard let chunk = try reader(256 * 1024) else { return Data() }   // 读失败沿闭包 throw 上抛
            transferred += Int64(chunk.count)
            if totalBytes > 0 { byteProgress?(transferred, totalBytes) }
            blockProgress?(transferred, totalBytes)   // 聚合账本观测（不受 total==0 闸门：
            return chunk                              // 块计数本身就是实测进度，账本自会钳）
        }
        // 末帧记账放在流外：Swift 不许逃逸闭包捕获 inout；抛出路径不记=未完成文件不产生末帧。
        if totalBytes > 0 { lastTotals = (transferred, totalBytes) }
    }

    /// 目录完成后的合并字节帧：把面板百分比从"目录内最后一文件的残余值"拉回 100%。
    /// 触发条件：目录期间有过字节帧（lastTotals 非空）且停在非 100%（t.done < t.total），
    /// 且与目录开始前记录的 bytesBefore 不同（防连续两个同 total 目录重复合并）。
    /// 发出后置 lastTotals=(total,total)——第二个合并帧被 t.done < t.total 自然挡住。
    private func mergeDirectoryProgress(_ byteProgress: ((Int64, Int64) -> Void)?,
                                        lastTotals: inout (done: Int64, total: Int64)?,
                                        bytesBefore: Int64?) {
        guard let t = lastTotals, t.total > 0, t.done < t.total, bytesBefore != t.total else { return }
        lastTotals = (t.total, t.total)
        byteProgress?(t.total, t.total)
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
