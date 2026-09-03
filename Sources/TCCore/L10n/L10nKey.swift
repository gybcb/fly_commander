import Foundation
/// 用户可见串的稳定 key。rawValue = 持久/调试用标识，非展示文案。
/// 新增串=加 case + 在 en/zh 两表各补一行。内核零文案，仅枚举。
public enum L10nKey: String, Hashable, CaseIterable {
    // —— 通用/对话框按钮 ——
    case cancel, browse, connect
    // —— 菜单 ——
    case menuFile
    case aboutApp, hideApp, quitApp
    case newTab, closeTab, newDirectory, rename, moveToTrash
    case copyToOtherPane, moveToOtherPane, sftpConnect, smbConnect
    case menuEdit, find, selectAll
    case menuView, preview, editItem, switchPane, parentDirectory, themeEllipsis
    case menuLanguage
    // —— 工具栏 ——
    case toolbarCopy, toolbarMove, toolbarDelete, toolbarConnect, toolbarTheme
    // —— 窗口标题（各 WindowController）——
    case themeWindowTitle, sftpWindowTitle, smbWindowTitle, searchWindowTitle
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
    case fieldPassword, fieldKeyFile, rememberPassword, fieldPassphrase
    case fieldHost, fieldPort, fieldUser, fieldKey, chooseWord
    case fillHost, invalidPort, chooseKeyFile, connecting
    case fieldServer, fieldShare, fieldDomain, fillServerShare
    case connectFailedPrefix
    // —— 仅供 fallback 回归测试，故意只进 en 表 ——
    case testFallbackProbe
    // —— 命令栏回显（InternalCommandExecutor，T6）——
    case syntaxError, copyInitiated, moveInitiated, themeOpened, unknownCommand
    case remoteSftpOnly, localCannotCdSftp, readFailed, lsSummary
    case mkdirUsage, mkdirDone, mkdirFailed
    case nothingToTransfer, notFoundItems, nothingToDelete, deleteInitiated
    case noFocusedItem, dirNotPreviewable, remoteNoPreview, dirNotEditable, remoteNoEdit
    case sftpUsage, sftpOpenedHost, sftpOpened
    case smbUsage, smbOpenedServer, smbOpened
    case tabCreated, tabClosed, tabCannotCloseLast, tabUsage
    case langUsageCurrent, langSet, langUnknown, langEnglishName, langChineseName
    // —— 命令栏帮助（helpText 拆条）——
    case helpHeader, helpCd, helpLs, helpMkdir, helpCopy, helpMove, helpDel
    case helpView, helpEdit, helpSftp, helpSmb, helpTabNew, helpTabClose
    case helpTheme, helpHelp, helpLang
    // —— 错误模板（TCError.l10nKey 映射；en 为内部稳定串镜像，zh 逐字搬原中文）——
    case errNotFound, errPermissionDenied, errBusy, errInvalidPath, errCancelled
    case errAlreadyExists, errAlreadyExistsBare, errDirExists, errCrossSourceDir
    case errNoSpace, errSFTPNotExecuted, errSMBMountFailed, errPutBackFailed, errUnknown
    // …（各任务按 key 清单增补本 enum）
}
