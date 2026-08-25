import Foundation

/// 底部命令栏的解析结果（TCCore 纯函数层，T7）。
public struct ParsedCommand: Equatable {
    public let name: String
    public let args: [String]

    public init(name: String, args: [String]) {
        self.name = name
        self.args = args
    }
}

public enum CommandLineError: Error, Equatable {
    case empty
    case unterminatedQuote
}

/// 命令分词器（纯函数，无 IO）。
/// - 空格/制表符分隔 token；
/// - 双引号包裹含空格片段（引号内的反斜杠转义 `"` 和 `\`）；
/// - 引号外反斜杠转义下一个字符（使其不被当作分隔符/引号）。
/// 首 token 为命令名，其余为参数。
public enum CommandLineParser {
    public static func parse(_ line: String) throws -> ParsedCommand {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex

        func push() {
            tokens.append(current)
            current = ""
        }

        while i < line.endIndex {
            let ch = line[i]
            let next = line.index(after: i)
            if inQuotes {
                if ch == "\\" && next < line.endIndex {
                    let esc = line[next]
                    if esc == "\"" || esc == "\\" {
                        current.append(esc)
                        i = next
                    } else {
                        // 引号内其它转义保留字面（如 \n → 反斜杠+n）
                        current.append(ch)
                        current.append(esc)
                        i = next
                    }
                } else if ch == "\"" {
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else {
                if ch == "\\" && next < line.endIndex {
                    current.append(line[next])
                    i = next
                } else if ch == "\"" {
                    inQuotes = true
                } else if ch == " " || ch == "\t" {
                    if !current.isEmpty { push() }
                } else {
                    current.append(ch)
                }
            }
            i = line.index(after: i)
        }
        if inQuotes { throw CommandLineError.unterminatedQuote }
        if !current.isEmpty { push() }

        guard let name = tokens.first, !name.isEmpty else { throw CommandLineError.empty }
        return ParsedCommand(name: name, args: Array(tokens.dropFirst()))
    }

    /// 把一个任意字符串编码为**单个 token**：经 `parse` 分词后能原样还原为该字符串。
    /// 仅当字符串含会破坏分词/引号语义的字符（空白、双引号、反斜杠）或为空时才加
    /// 双引号包裹（引号内 `\` 与 `"` 转义），否则原样返回（简洁）。
    /// 用途：把文件系统名写回命令栏而不被空格拆成多个参数（`cd My Documents` →
    /// `cd "My Documents"`）。这是把"文本缓冲"表示与"单项"语义对齐的唯一可靠方式。
    public static func encodeToken(_ s: String) -> String {
        let needsQuoting = s.isEmpty
            || s.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" })
        guard needsQuoting else { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
