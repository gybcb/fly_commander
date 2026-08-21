import Foundation

public struct DirectoryPage {
    public let path: TCPath
    public let items: [FileItem]
    public let hasMore: Bool

    public init(path: TCPath, items: [FileItem], hasMore: Bool = false) {
        self.path = path
        self.items = items
        self.hasMore = hasMore
    }
}
