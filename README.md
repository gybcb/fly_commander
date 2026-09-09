# FlyCommander

A keyboard-first, dual-pane file manager for macOS, modeled on Total Commander.
Built with Swift (AppKit) and a headless, unit-tested core (`TCCore`).

Licensed under **AGPL-3.0-or-later** (SPDX: `AGPL-3.0-or-later`) — see [License](#license).

## Requirements
- macOS 14 (Sonoma) or later
- Xcode 15+ (for `swift build` / `swift test` / `swift run`)
- Release 二进制目前仅覆盖 **Apple Silicon (arm64)**；Intel Mac 请自行从源码构建

## 安装（Alpha：未签名、未公证）

本项目不使用 Apple 开发者证书，因此 GitHub Release 下载的应用会被 Gatekeeper
拦截（提示「无法验证开发者」甚至「已损坏」——**这不是应用损坏，只是没公证**）。
步骤：

1. Releases 页下载 `FlyCommander_<版本>_arm64.dmg`，双击挂载；
2. 把 FlyCommander.app 拖进 Applications；
3. 首次启动任选一种放行：
   - System Settings → Privacy & Security → 底部「**仍要打开**」（macOS Sequoia
     起官方唯一路径；老的右键→打开对未公证应用已不可靠）；
   - 或终端：`xattr -dr com.apple.quarantine /Applications/FlyCommander.app`

构建与发布由 GitHub Actions 自动执行（`.github/workflows/`，tag `v*` 触发）。

## Build & run
    swift build          # build library + app
    swift test           # run all unit tests (TCCore + app, incl. local-sshd SFTP e2e)
    swift run FlyCommander

UI regression (Tier 2, real windows):
    xcodegen generate
    xcodebuild test -scheme FlyCommander -destination 'platform=macOS'

## Keyboard (keyboard-first, TC style)
| Key | Action |
|---|---|
| ↑ / ↓ / PgUp / PgDn / Home / End | move focus |
| → / Return | enter directory |
| ← / Backspace | go to parent |
| Ctrl+←/→ , Tab | switch active pane |
| Space / Option+Q | toggle mark |
| Ctrl+↑/↓ | additive mark |
| Shift+↑/↓ | range mark |
| Esc | clear marks |
| Cmd+A | select all |
| F3 / F4 | built-in preview / open with external editor |
| F5 / F6 | copy / move to other pane |
| F7 | new directory |
| F8 | delete (local → Trash; remote → confirm + direct delete) |
| Fn+Delete | rename |
| Cmd+F | recursive filename search |
| Any printable key | start typing a command (TC command line) |

## Command line (TC-style, internal commands only)

Type at the bottom command bar (focus is in the file list; plain characters
are captured, Shift+letter works, arrow/F keys keep their TC behavior).
No shell passthrough — commands act on the panes only.

| Command | Meaning |
|---|---|
| `cd [path]` | enter directory (no arg → local home / remote home; remote pane only accepts `sftp://host:port/path`) |
| `ls` | echo active pane item count |
| `mkdir name` | new directory (local or remote) |
| `copy` / `move` | copy/move marked items to the other pane (same as F5/F6; cross-source runs in background) |
| `del [items… \| *]` | delete (no arg = focused item; remote = confirm + direct delete, no trash) |
| `view` / `edit` | preview focused file / open with external editor (local only) |
| `sftp [host[:port]]` | open the SFTP connection window (host/port prefilled) |
| `help` | list commands |

## SFTP remote (P4)

- Connect via the toolbar "连接" button or the `sftp` command.
- Auth: SSH key file (optionally with passphrase) **or** username + password.
  Passwords can be stored in the macOS Keychain ("记住密码").
- Remote panes support: browsing, upload/download, move/copy/rename/mkdir,
  and direct delete (no trash on the server — always confirmed).
- Remote paths use the `sftp://host:port/path` scheme; `cd` with no argument
  returns to the remote home directory.
- Implemented on top of [Traversio](https://github.com/GitSwiftHQ/Traversio)
  (SSH/SFTP library).

## License

FlyCommander 以 **GNU Affero General Public License v3.0（或后续版本）** 授权
（SPDX: `AGPL-3.0-or-later`），与全文见 [LICENSE](LICENSE)。之所以采用 AGPL：
应用**静态链接**了同样以 AGPL-3.0-or-later（+ 商业双许可）发布的依赖
[Traversio](https://github.com/GitSwiftHQ/Traversio)，按 GPL/AGPL 的链接规则，
整个组合作品须以同协议授权。

- **对应源码（corresponding source）**：每个 GitHub Release 都与同名的 git tag
  一一对应，该 tag 的仓库内容（`Package.swift` / `Package.resolved` /
  `project.yml` / 全部源码 / 构建 workflow）即构建该 `.app` 的完整输入——Release
  页的 `Source code` 归档与 [`tree/<tag>`](https://github.com/gybcb/fly_commander/tags)
  即为可复现本二进制的对应源码。
- **AGPL §13（网络交互条款）在本项目不实际触发**：FlyCommander 是运行在你自己
  机器上的桌面程序，不对外提供网络服务；它的 SFTP/SMB 功能是「作为客户端访问
  你的服务器」，不构成 §13 所指的「通过计算机网络远程使用本程序」。
- **商业许可**：若需在闭源产品中 incorporating Traversio，请直接向 GitSwift
  购买其商业许可（见 Traversio 仓库 `COMMERCIAL-LICENSE.md`）；FlyCommander
  本身只提供 AGPL 授权。
- 若你为闭源分发而需要替换 SFTP 后端，可移除 Traversio 依赖（删除
  `Sources/FlyCommander/Remote/` 的 SFTP 接线），此组合变更不影响其余代码的授权。

## Notes
- Local delete (F8) moves items to the macOS Trash (recoverable).
- Remote delete has no trash — a confirmation dialog warns it is permanent.
- Because this is a locally-run, non-sandboxed app, macOS may prompt for
  authorization the first time you open protected folders (e.g. ~/Desktop,
  ~/Documents). Grant access in System Settings → Privacy & Security if needed.
- Roadmap status: P0–P2 done, P3 (archives) skipped by user, P4 (command line
  + SFTP) done. P5 (tabs & view modes) remains.
