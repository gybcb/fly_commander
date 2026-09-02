import Foundation
/// 用户可见串的稳定 key。rawValue = 持久/调试用标识，非展示文案。
/// 新增串=加 case + 在 en/zh 两表各补一行。内核零文案，仅枚举。
public enum L10nKey: String, Hashable, CaseIterable {
    // —— 通用/对话框按钮 ——
    case ok, cancel, create, `default`, close, browse, connect, forget
    // —— 菜单 ——
    case menuFile
    case aboutApp, hideApp, quitApp
    case newTab, closeTab, newDirectory, rename, moveToTrash
    case copyToOtherPane, moveToOtherPane, sftpConnect, smbConnect
    case menuEdit, find, selectAll
    case menuView, preview, editItem, switchPane, parentDirectory, themeEllipsis
    // —— 工具栏 ——
    case toolbarCopy, toolbarMove, toolbarDelete, toolbarConnect, toolbarTheme
    // —— 窗口/系统 ——
    case showNextPrevTab
    // —— 命令回显（AppKit 层 InternalCommandExecutor）——
    case entered, cannotEnterNotDirectory
    // —— 状态栏前缀 ——
    case statusErrorPrefix
    // —— 主窗对话框 / 列头 / 标签辅助串 ——
    case renameTitle, newDirTitle, okBtn, createBtn, cancelBtn
    case conflictTitle, conflictQuestion, overwrite, skip, overwriteAll, skipAll
    case trashConfirm, deleteWord, remoteDeleteConfirm, remoteNoTrash
    case selectedCount, cannotOpenFile
    case colName, colSize, colDate
    case closeTabTip, newTabTip
    // —— 搜索窗（SearchViewController）——
    case searchRootLabel, searchHint, startSearch, stop, newSearch
    case searching, searchingChecked, searchStopped, searchSummary, searchNone, stopping
    case colFile
    // —— 预览窗（PreviewViewController / PreviewWindowController）——
    case openWithDefault, previewTruncBanner, previewOfFileTotal, previewLongLineTrunc
    case lineTruncatedMark, cannotReadImage, cannotPreview
    case previewWindowTitle, previewWindowTitlePlain
    // —— 主题窗（ThemeViewController / ThemeWindowController）——
    case appearance, followSystem, lightMode, darkMode
    case accentColorHint, fileColorHint, addRule, restoreDefaults
    // —— 命令栏（CommandLineBar）——
    case commandBarPrompt, commandBarPlaceholder
    // —— SFTP/SMB 连接窗（ConnectionViewController / SMBConnectionViewController）——
    case fieldPassword, fieldKeyFile, rememberPassword
    case fieldHost, fieldPort, fieldUser, fieldKey, chooseWord
    case fillHost, invalidPort, chooseKeyFile, connecting
    case fieldServer, fieldShare, fieldDomain, fillServerShare
    case connectFailedPrefix
    // —— 仅供 fallback 回归测试，故意只进 en 表 ——
    case testFallbackProbe
    // …（各任务按 key 清单增补本 enum）
}
