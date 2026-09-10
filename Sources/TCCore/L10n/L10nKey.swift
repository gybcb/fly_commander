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
    case toolbarCopy, toolbarMove, toolbarDelete, toolbarConnect, toolbarSMB, toolbarTheme
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
    case errPathOutsideShare, errPathEscaped, errMountPointHint
    case errAuthRejected, errSFTPConnectFailed
    // —— OperationState 通道（Plan B：内核只发 key，边界组装）——
    // running 标签复用 Plan A 现键（rename / newDirectory）；done 成品句用 op*Done。
    case opCopying, opMoving, opDeleteRunning, opDeleteDone
    case opRenameDone, opMkdirDone, opSearchRunning, opSearchDone
    case statusRunning, statusDone, statusDoneWarn, warnSourceLeftover
    /// done+警告多条 warningLines 的连接分隔符（随语言：en "; " / zh 全角"；"），
    /// 防英文状态栏里流出中文标点（原硬编码 separator 违规项）。
    case statusWarnJoin
    // —— 右键上下文菜单（PaneTableView 弹出）——
    case menuOpen, openWithMenu, showInFinder, share
    /// 远端文件回车打开：先下载到本地缓存（网络 RTT，状态栏提示）。
    case remoteDownloading
    // —— 窗格筛选（TabBar 常驻按钮 + 展开的筛选行）——
    /// filterMatchCount 的两个参数是 **可见数 / 总数**。
    case filterButtonTip, filterPlaceholder, filterClearTip, filterMatchCount
    // —— 传输进度面板（TransferProgressWindowController）——
    case transferring, transSpeed, transRemaining, transCancel, transDone
    /// transServerSide/transRelayed = 副标题（实际传输路径）；
    /// transRelayedReason 携回退原因成品串（execRejected/cpMissing/…各自的串）。
    case transServerSide, transRelayed, transRelayedExecRejected, transRelayedCpMissing,
         transRelayedUnsupportedFlags, transRelayedChannelGone
    // —— 目录收藏夹（DirectoryFavoritesStore + TabBar 箭头下拉）——
    case favoritesButtonTip, addFavorite, removeFavorite, favoriteAdded, favoriteRemoved,
         favoritesNeedReconnect
    // —— 隐藏文件显隐切换（⌘⇧. 菜单项 + FilePane.showHidden 闸门）——
    case toggleHiddenFiles, hiddenFilesShown, hiddenFilesHidden
    // —— 手动刷新（View 菜单 ⌃R + 命令栏 refresh；自动刷新的手动兜底）——
    case refresh, refreshed, helpRefresh
}
