import Foundation
/// 中英两表的内存文案表。跨模块（FlyCommander 层）读取，故 public。
public enum L10nTable {
    public static let en: [L10nKey: String] = [
        .ok: "OK", .cancel: "Cancel", .create: "Create", .close: "Close",
        .browse: "Browse…", .connect: "Connect",
        .entered: "Entered {0}", .cannotEnterNotDirectory: "Cannot enter: {0} (missing or not a directory)",
        .statusErrorPrefix: "Error: ",
        .menuFile: "File",
    ]
    public static let zh: [L10nKey: String] = [
        .ok: "确定", .cancel: "取消", .create: "创建", .close: "关闭",
        .browse: "浏览…", .connect: "连接",
        .entered: "已进入 {0}", .cannotEnterNotDirectory: "无法进入：{0}（不存在或不是目录）",
        .statusErrorPrefix: "错误：",
        .menuFile: "文件",
    ]
}
