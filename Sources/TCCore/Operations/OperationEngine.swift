import Foundation

public final class OperationEngine {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    public func performCopy(_ items: [FileItem], to destDir: TCPath,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        let total = items.count
        for (i, item) in items.enumerated() {
            let src = item.path.url
            let dst = destDir.url.appendingPathComponent(item.name)
            var dstIsDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir)
            if exists {
                if skipAll { progress?(i + 1, total); continue }
                if overwriteAll { do { try fm.removeItem(at: dst) } catch { throw asTCError(error) } }
                else if let choice = prompt?(item.path, TCPath(url: dst)) {
                    switch choice {
                    case .overwrite: do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                    case .overwriteAll: overwriteAll = true; do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                    case .skip: progress?(i + 1, total); continue
                    case .skipAll: skipAll = true; progress?(i + 1, total); continue
                    case .cancel: throw TCError.cancelled
                    }
                } else {
                    do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                }
            }
            do { try fm.copyItem(at: src, to: dst) } catch { throw asTCError(error) }
            progress?(i + 1, total)
        }
    }

    public func performMove(_ items: [FileItem], to destDir: TCPath,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        var moved: [(from: URL, to: URL)] = []
        let total = items.count
        for (i, item) in items.enumerated() {
            let src = item.path.url
            let dst = destDir.url.appendingPathComponent(item.name)
            var dstIsDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir)
            if exists {
                if skipAll { progress?(i + 1, total); continue }
                if overwriteAll { do { try fm.removeItem(at: dst) } catch { throw asTCError(error) } }
                else if let choice = prompt?(item.path, TCPath(url: dst)) {
                    switch choice {
                    case .overwrite: do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                    case .overwriteAll: overwriteAll = true; do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                    case .skip: progress?(i + 1, total); continue
                    case .skipAll: skipAll = true; progress?(i + 1, total); continue
                    case .cancel: throw TCError.cancelled
                    }
                } else {
                    do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                }
            }
            do {
                try fm.moveItem(at: src, to: dst)
                moved.append((dst, src))
            } catch {
                for pair in moved.reversed() { try? fm.moveItem(at: pair.from, to: pair.to) }
                throw asTCError(error)
            }
            progress?(i + 1, total)
        }
    }

    public func performRename(_ item: FileItem, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw TCError.invalidPath(newName) }
        guard let parent = item.path.parent else { throw TCError.invalidPath(item.path.pathString) }
        let dst = parent.url.appendingPathComponent(trimmed)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dst.path, isDirectory: &isDir) {
            throw TCError.unknown("已存在同名：\(trimmed)")
        }
        do { try fm.moveItem(at: item.path.url, to: dst) } catch { throw asTCError(error) }
    }

    @discardableResult
    public func performMakeDirectory(_ name: String, in dir: TCPath) throws -> TCPath {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw TCError.invalidPath(name) }
        let newDir = dir.joining(trimmed)
        do { try fm.createDirectory(at: newDir.url, withIntermediateDirectories: false) }
        catch { throw asTCError(error) }
        return newDir
    }
}
