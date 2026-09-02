import Foundation
/// 中英两表的内存文案表。跨模块（FlyCommander 层）读取，故 public。
public enum L10nTable {
    public static let en: [L10nKey: String] = [
        .ok: "OK", .cancel: "Cancel", .create: "Create", .close: "Close",
        .browse: "Browse…", .connect: "Connect",
        .entered: "Entered {0}", .cannotEnterNotDirectory: "Cannot enter: {0} (missing or not a directory)",
        .statusErrorPrefix: "Error: ",
        .menuFile: "File",
        .aboutApp: "About FlyCommander", .hideApp: "Hide FlyCommander", .quitApp: "Quit FlyCommander",
        .newTab: "New Tab", .closeTab: "Close Tab", .newDirectory: "New Directory",
        .rename: "Rename", .moveToTrash: "Move to Trash",
        .copyToOtherPane: "Copy to Other Pane", .moveToOtherPane: "Move to Other Pane",
        .sftpConnect: "SFTP Connect…", .smbConnect: "SMB Connect…",
        .menuEdit: "Edit", .find: "Find", .selectAll: "Select All",
        .menuView: "View", .preview: "Preview", .editItem: "Edit",
        .switchPane: "Switch Pane", .parentDirectory: "Parent Directory", .themeEllipsis: "Theme…",
        .toolbarCopy: "Copy", .toolbarMove: "Move", .toolbarDelete: "Delete",
        .toolbarConnect: "Connect", .toolbarTheme: "Theme",
        .showNextPrevTab: "Show Next/Previous Window Tab",
        .testFallbackProbe: "__PROBE_EN__",   // 仅 en 表：验证 zh→en 兜底
    ]
    public static let zh: [L10nKey: String] = [
        .ok: "确定", .cancel: "取消", .create: "创建", .close: "关闭",
        .browse: "浏览…", .connect: "连接",
        .entered: "已进入 {0}", .cannotEnterNotDirectory: "无法进入：{0}（不存在或不是目录）",
        .statusErrorPrefix: "错误：",
        .menuFile: "文件",
        .aboutApp: "关于 FlyCommander", .hideApp: "隐藏 FlyCommander", .quitApp: "退出 FlyCommander",
        .newTab: "新建标签页", .closeTab: "关闭标签页", .newDirectory: "新建目录",
        .rename: "重命名", .moveToTrash: "移到废纸篓",
        .copyToOtherPane: "复制到另一窗格", .moveToOtherPane: "移动到另一窗格",
        .sftpConnect: "SFTP 连接…", .smbConnect: "SMB 连接…",
        .menuEdit: "编辑", .find: "查找", .selectAll: "全选",
        .menuView: "查看", .preview: "预览", .editItem: "编辑",
        .switchPane: "切换窗格", .parentDirectory: "上级目录", .themeEllipsis: "主题…",
        .toolbarCopy: "复制", .toolbarMove: "移动", .toolbarDelete: "删除",
        .toolbarConnect: "连接", .toolbarTheme: "主题",
        .showNextPrevTab: "显示下一/上一个窗口标签页",
    ]
}
