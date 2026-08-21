import Foundation

public protocol FileSource {
    func listDirectory(_ path: TCPath) throws -> [FileItem]
    func isDirectory(_ path: TCPath) -> Bool
}
