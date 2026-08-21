import Foundation

public enum ConflictChoice: Equatable {
    case overwrite, skip, overwriteAll, skipAll, cancel
}

public typealias ConflictPrompt = (_ source: TCPath, _ destination: TCPath) -> ConflictChoice
