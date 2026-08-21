import Foundation

public struct FileItem: Identifiable, Hashable, Equatable {
    public let id: String
    public let path: TCPath
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date
    public let isHidden: Bool
    public let isReadOnly: Bool
    public let isExecutable: Bool

    public init(id: String, path: TCPath, name: String, isDirectory: Bool, size: Int64,
                modificationDate: Date, isHidden: Bool, isReadOnly: Bool, isExecutable: Bool) {
        self.id = id
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.isHidden = isHidden
        self.isReadOnly = isReadOnly
        self.isExecutable = isExecutable
    }
}
