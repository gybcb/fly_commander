# FlyCommander

A keyboard-first, dual-pane file manager for macOS, modeled on Total Commander.
Built with Swift (AppKit) and a headless, unit-tested core (`TCCore`).

## Requirements
- macOS 14 (Sonoma) or later
- Xcode 15+ (for `swift build` / `swift test` / `swift run`)

## Build & run
    swift build          # build library + app
    swift test           # run all unit tests (TCCore + app key/color mapping)
    swift run FlyCommander

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
| Cmd+A | select all |
| F5 / F6 | copy / move to other pane |
| F7 | new directory |
| F8 | delete to Trash |
| Fn+Delete | rename |

## Notes
- Delete (F8) moves items to the macOS Trash (recoverable).
- Because this is a locally-run, non-sandboxed app, macOS may prompt for
  authorization the first time you open protected folders (e.g. ~/Desktop,
  ~/Documents). Grant access in System Settings → Privacy & Security if needed.
- This is a P0/P1 milestone. Viewers/editors (F3/F4), archive (P3), remote
  (FTP/SMB, P4), tabs & view modes (P5) are planned follow-ups.
