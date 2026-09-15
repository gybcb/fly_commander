# FlyCommander

[English](README.md) | [简体中文](README_zh.md)

面向 macOS 的键盘优先双栏文件管理器，对标 Total Commander。
Swift + AppKit 编写，核心为无头、全单元测试的 `TCCore`。

以 **AGPL-3.0-or-later**（SPDX: `AGPL-3.0-or-later`）授权——见[许可](#许可)。

## 环境要求
- macOS 14（Sonoma）或更新系统
- Xcode 15+（用于 `swift build` / `swift test` / `swift run`）
- Release 二进制目前仅覆盖 **Apple Silicon (arm64)**；Intel Mac 请自行从源码构建

## 安装（Alpha：未签名、未公证）

本项目不使用 Apple 开发者证书，因此从 GitHub Release 下载的应用会被
Gatekeeper 拦截（提示「无法验证开发者」甚至「已损坏」——**这不是应用损坏，
只是没公证**）。步骤：

1. Releases 页下载 `FlyCommander_<版本>_arm64.dmg`，双击挂载；
2. 把 FlyCommander.app 拖进 Applications；
3. 首次启动任选一种放行：
   - 系统设置 → 隐私与安全性 → 底部「**仍要打开**」（macOS Sequoia
     起官方唯一路径；老的右键→打开对未公证应用已不可靠）；
   - 或终端执行：`xattr -dr com.apple.quarantine /Applications/FlyCommander.app`

构建与发布由 GitHub Actions 自动执行（`.github/workflows/`，tag `v*` 触发）。

## 构建与运行
    swift build          # 构建库 + App
    swift test           # 全量单元测试（TCCore + App，含本机 sshd 的 SFTP e2e
                         # 与进程内 mini FTP 服务器 e2e）
    swift run FlyCommander

UI 回归测试（第二梯队，真实窗口）：
    xcodegen generate
    xcodebuild test -scheme FlyCommander -destination 'platform=macOS'

## 快捷键（键盘优先，TC 风格）
| 按键 | 动作 |
|---|---|
| ↑ / ↓ / PgUp / PgDn / Home / End | 移动焦点 |
| → / Return | 进入目录 |
| ← / Backspace | 返回上级 |
| Ctrl+←/→ , Tab | 切换活动窗格 |
| Space / Option+Q | 标记/取消标记 |
| Ctrl+↑/↓ | 追加标记 |
| Shift+↑/↓ | 区间标记 |
| Esc | 清除标记 |
| Cmd+A | 全选 |
| F3 / F4 | 内置预览 / 外部编辑器打开 |
| F5 / F6 | 复制到 / 移动到另一窗格 |
| F7 | 新建目录 |
| F8 | 删除（本地 → 废纸篓；远端 → 确认后直接删除） |
| Fn+Delete | 重命名 |
| Cmd+F | 递归文件名搜索 |
| 任意可打印键 | 开始键入命令（TC 命令行） |

## 命令行（TC 风格，仅内部命令）

在底部命令栏键入（焦点在文件列表时普通字符被捕获进命令栏，Shift+字母可用，
方向键/F 键保持 TC 行为）。无 shell 透传——命令只作用于窗格。

| 命令 | 含义 |
|---|---|
| `cd [路径]` | 进入目录（无参数 → 本地 home / 远端 home；远端窗格只接受其自身协议前缀，如 `sftp://host:port/path`） |
| `ls` | 显示当前窗格条目数 |
| `mkdir 名称` | 新建目录（本地或远端） |
| `copy` / `move` | 把标记条目复制/移动到另一窗格（同 F5/F6；跨源在后台执行） |
| `del [条目… \| *]` | 删除（无参数 = 焦点条目；远端 = 确认后直接删除，不进废纸篓） |
| `view` / `edit` | 预览焦点文件 / 外部编辑器打开（仅本地） |
| `sftp [host[:port]]` | 打开「连接到远端」对话框并预选 SFTP 协议（预填主机/端口） |
| `smb [服务器]` | 同上，预选 SMB 协议 |
| `ftp [host[:port]]` | 同上，预选 FTP 协议 |
| `tab [new\|close]` | 新建 / 关闭窗格标签页 |
| `theme` | 打开主题窗口 |
| `lang [en\|zh]` | 切换界面语言 |
| `refresh` | 重新加载当前窗格 |
| `update` | 检查新版本 |
| `help` | 列出全部命令 |

## 远端连接（SFTP / SMB / FTP）

工具栏只有一个**连接到远端**按钮，打开同一个对话框，顶部分段控件切换三种协议。
已保存连接跨启动持久化（密码存 macOS 钥匙串，「记住密码」）。

- **SFTP** —— 基于 [Traversio](https://github.com/GitSwiftHQ/Traversio)
  （SSH/SFTP 库）实现。认证：SSH 密钥文件（可带口令）**或**用户名+密码。
  路径形如 `sftp://host:port/path`。
- **SMB** —— 通过 macOS `mount_smbfs` 挂载共享后按本地源浏览。
  路径形如 `smb://server/share/path`。
- **FTP** —— 内置纯 Swift FTP 客户端（Network.framework，零第三方依赖）：
  浏览、上传/下载、移动/重命名/建目录/删除，走与本地/SFTP 相同的
  `FileSource` 流式接口。支持明文 FTP（21 端口）与**隐式 FTPS**
  （990 端口，连接即 TLS）。*暂不支持显式 `AUTH TLS`。*
  路径形如 `ftp://host[:port]/path`。
- 远端窗格全部支持：浏览、上传/下载、移动/复制/重命名/建目录、
  直接删除（服务器上没有废纸篓——一律弹确认）。`cd` 不带参数回到远端 home。

## 许可

FlyCommander 以 **GNU Affero General Public License v3.0（或后续版本）** 授权
（SPDX: `AGPL-3.0-or-later`），全文见 [LICENSE](LICENSE)。之所以采用 AGPL：
应用**静态链接**了同样以 AGPL-3.0-or-later（+ 商业双许可）发布的依赖
[Traversio](https://github.com/GitSwiftHQ/Traversio)，按 GPL/AGPL 的链接规则，
整个组合作品须以同协议授权。

- **对应源码（corresponding source）**：每个 GitHub Release 都与同名的 git tag
  一一对应，该 tag 的仓库内容（`Package.swift` / `Package.resolved` /
  `project.yml` / 全部源码 / 构建 workflow）即构建该 `.app` 的完整输入——Release
  页的 `Source code` 归档与 [`tree/<tag>`](https://github.com/gybcb/fly_commander/tags)
  即为可复现本二进制的对应源码。
- **AGPL §13（网络交互条款）在本项目不实际触发**：FlyCommander 是运行在你自己
  机器上的桌面程序，不对外提供网络服务；它的 SFTP/SMB/FTP 功能是「作为客户端访问
  你的服务器」，不构成 §13 所指的「通过计算机网络远程使用本程序」。
- **商业许可**：若需在闭源产品中 incorporation Traversio，请直接向 GitSwift
  购买其商业许可（见 Traversio 仓库 `COMMERCIAL-LICENSE.md`）；FlyCommander
  本身只提供 AGPL 授权。
- 若你为闭源分发而需要替换 SFTP 后端，可移除 Traversio 依赖（删除
  `Sources/FlyCommander/Remote/` 的 SFTP 接线），此组合变更不影响其余代码的授权。

## 备注
- 本地删除（F8）移入 macOS 废纸篓（可恢复）。
- 远端删除没有废纸篓——确认对话框会警告其不可恢复。
- 本应用为本地运行的非沙盒程序，首次打开受保护目录（如 ~/Desktop、
  ~/Documents）时 macOS 可能弹出授权提示，请在系统设置 → 隐私与安全性中放行。
- 路线图状态：P0–P4 已完成；P3（压缩包）按用户要求跳过；P5（标签页与视图
  模式）部分完成——标签页已上线，视图模式待做。
