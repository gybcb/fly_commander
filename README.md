# FlyCommander

A keyboard-first, dual-pane file manager for macOS, modeled on Total Commander.
Built with Swift (AppKit) and a headless, unit-tested core (`TCCore`).

## Requirements
- macOS 14 (Sonoma) or later
- Xcode 15+ (for `swift build` / `swift test` / `swift run`)

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
- **License note:** Traversio is AGPL-3.0. This project is a local,
  personal-use tool and is **not distributed**; therefore the AGPL's
  distribution obligations do not apply. If you ever ship or distribute a
  derived version, review the AGPL-3.0 terms and comply (source disclosure,
  etc.).

## Notes
- Local delete (F8) moves items to the macOS Trash (recoverable).
- Remote delete has no trash — a confirmation dialog warns it is permanent.
- Because this is a locally-run, non-sandboxed app, macOS may prompt for
  authorization the first time you open protected folders (e.g. ~/Desktop,
  ~/Documents). Grant access in System Settings → Privacy & Security if needed.
- Roadmap status: P0–P2 done, P3 (archives) skipped by user, P4 (command line
  + SFTP) done. P5 (tabs & view modes) remains.
