# FlyCommander

[English](README.md) | [简体中文](README_zh.md)

A keyboard-first, dual-pane file manager for macOS, modeled on Total Commander.
Built with Swift (AppKit) and a headless, unit-tested core (`TCCore`).

Licensed under **AGPL-3.0-or-later** (SPDX: `AGPL-3.0-or-later`) — see [License](#license).

## Requirements
- macOS 14 (Sonoma) or later
- Xcode 15+ (for `swift build` / `swift test` / `swift run`)
- Release binaries are provided per CPU architecture:
  `FlyCommander_<version>_arm64.dmg` (Apple Silicon) and
  `FlyCommander_<version>_x86_64.dmg` (Intel); the in-app updater automatically
  picks the dmg matching your machine

## Installation (Alpha: unsigned, not notarized)

This project does not use an Apple Developer certificate, so the app downloaded
from GitHub Releases is blocked by Gatekeeper (it may say "cannot verify
developer" or even "is damaged" — **the app is not damaged, it is merely not
notarized**). Steps:

1. From the Releases page download `FlyCommander_<version>_arm64.dmg` (Apple
   Silicon) or `FlyCommander_<version>_x86_64.dmg` (Intel), and mount it;
2. Drag FlyCommander.app into Applications;
3. On first launch, allow it one of two ways:
   - System Settings → Privacy & Security → "**Open Anyway**" at the bottom
     (the only official path since macOS Sequoia; the old right-click → Open is
     no longer reliable for un-notarized apps);
   - or in Terminal: `xattr -dr com.apple.quarantine /Applications/FlyCommander.app`

Builds and releases run automatically via GitHub Actions
(`.github/workflows/`, triggered by `v*` tags).

## Build & run
    swift build          # build library + app
    swift test           # run all unit tests (TCCore + app, incl. local-sshd SFTP e2e
                         # and an in-process mini FTP server e2e)
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
| `cd [path]` | enter directory (no arg → local home / remote home; a remote pane only accepts its own scheme, e.g. `sftp://host:port/path`) |
| `ls` | echo active pane item count |
| `mkdir name` | new directory (local or remote) |
| `copy` / `move` | copy/move marked items to the other pane (same as F5/F6; cross-source runs in background) |
| `del [items… \| *]` | delete (no arg = focused item; remote = confirm + direct delete, no trash) |
| `view` / `edit` | preview focused file / open with external editor (local only) |
| `sftp [host[:port]]` | open the Connect-to-Remote dialog with protocol SFTP preselected (host/port prefilled) |
| `smb [server]` | same dialog, protocol SMB preselected |
| `ftp [host[:port]]` | same dialog, protocol FTP preselected |
| `tab [new\|close]` | open / close a pane tab |
| `theme` | open the theme window |
| `lang [en\|zh]` | switch UI language |
| `refresh` | reload the active pane |
| `update` | check for a new version |
| `help` | list commands |

## Remote connections (SFTP / SMB / FTP)

One toolbar button (**Connect to Remote**) opens a single dialog that switches
between the three protocols. Saved connections persist across launches
(passwords live in the macOS Keychain, "Remember password").

- **SFTP** — implemented on top of
  [Traversio](https://github.com/GitSwiftHQ/Traversio) (SSH/SFTP library).
  Auth: SSH key file (optionally with passphrase) **or** username + password.
  Paths use the `sftp://host:port/path` scheme.
- **SMB** — mounts the share via macOS `mount_smbfs` and browses it as a local
  source. Paths use the `smb://server/share/path` scheme.
- **FTP** — a built-in pure-Swift FTP client (Network.framework, no third-party
  dependency): browsing, upload/download, move/rename/mkdir/delete, streaming
  transfers through the same `FileSource` interface as local/SFTP. Supports
  plaintext FTP (port 21) and **implicit FTPS** (port 990, TLS from the first
  byte). *Explicit `AUTH TLS` is not supported yet.* Paths use the
  `ftp://host[:port]/path` scheme.
- All remote panes support: browsing, upload/download,
  move/copy/rename/mkdir, and direct delete (no trash on the server — always
  confirmed). `cd` with no argument returns to the remote home directory.

## License

FlyCommander is licensed under the **GNU Affero General Public License v3.0
(or any later version)** (SPDX: `AGPL-3.0-or-later`); see
[LICENSE](LICENSE) for the full text. The reason for AGPL: the app **statically
links** [Traversio](https://github.com/GitSwiftHQ/Traversio), a dependency
itself published under AGPL-3.0-or-later (+ commercial dual license), and the
GPL/AGPL linking rules require the whole combined work to carry the same license.

- **Corresponding source**: every GitHub Release maps one-to-one to a git tag of
  the same name; the repository content at that tag (`Package.swift` /
  `Package.resolved` / `project.yml` / all sources / the build workflow) is the
  complete input that builds the `.app` — the `Source code` archive on the
  Release page and the [`tree/<tag>`](https://github.com/gybcb/fly_commander/tags)
  view are the corresponding source to reproduce the binary.
- **AGPL §13 (network interaction clause) does not actually trigger here**:
  FlyCommander is a desktop program running on your own machine and provides no
  network service; its SFTP/SMB/FTP features are "accessing *your* server as a
  client", which is not "using the program remotely over a computer network" in
  the sense of §13.
- **Commercial licensing**: to incorporate Traversio into a closed-source
  product, purchase its commercial license directly from GitSwift (see
  `COMMERCIAL-LICENSE.md` in the Traversio repository); FlyCommander itself is
  offered under AGPL only.
- If you need to replace the SFTP backend for closed-source distribution, you can
  remove the Traversio dependency (delete the SFTP wiring under
  `Sources/FlyCommander/Remote/`); that combination change does not affect the
  license of the rest of the code.

## Notes
- Local delete (F8) moves items to the macOS Trash (recoverable).
- Remote delete has no trash — a confirmation dialog warns it is permanent.
- Because this is a locally-run, non-sandboxed app, macOS may prompt for
  authorization the first time you open protected folders (e.g. ~/Desktop,
  ~/Documents). Grant access in System Settings → Privacy & Security if needed.
- Roadmap status: P0–P4 done; P3 (archives) skipped by user; P5 (tabs & view
  modes) partially done — tabs shipped, view modes remain.
