# FlyCommander P0/P1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a keyboard-first, dual-pane Total Commander clone on macOS (AppKit), delivering a P0 skeleton plus a working P1 core (browse + copy/move/delete/rename/mkdir + selection model + status/command bars) with a fully unit-tested headless core.

**Architecture:** A single root Swift Package with three targets: `TCCore` (headless pure-Swift engine, zero AppKit, 100% unit-testable: paths, directory model, selection, command routing, file-operation pipeline, focus/workspace, data source, events), `FlyCommander` (thin AppKit view layer: window, two `NSCollectionView` panes, command/status bars, key dispatch, role→color mapping), and `TCCoreTests`. The AppKit layer forwards keyboard/click input to the core and renders core state via callbacks; it never mutates core state directly.

**Tech Stack:** Swift 5 language mode, AppKit, Foundation, Dispatch. No third-party dependencies. Built/tested with `swift build` / `swift test`; run with `swift run FlyCommander` (SPM executable target bootstrapping `NSApplication`).

**Spec:** `docs/superpowers/specs/2026-08-21-fly-commander-design.md`

## Global Constraints

- **macOS 14 minimum.** `Package.swift` sets `platforms: [.macOS(.v14)]`.
- **Swift 5 language mode.** The root manifest is `swift-tools-version: 5.9`, which compiles in Swift 5 mode by default (no `swiftSettings` needed — `.swiftLanguageVersion(.v5)` is not in the 5.9 manifest API on this toolchain). This avoids strict-concurrency/Sendable friction.
- **No third-party dependencies.** Only `Foundation`, `AppKit`, `Dispatch`.
- **Layering.** `TCCore` must **not** `import AppKit`. `FlyCommander` may `import AppKit` and `import TCCore`.
- **Naming.** App target `FlyCommander`, library target `TCCore`, test target `TCCoreTests`.
- **Local-use build.** No App Sandbox, no code signing. Run via `swift run FlyCommander`.
- **Keyboard-first.** F-keys drive operations: F5 copy, F6 move, F7 mkdir, F8 delete. `Backspace(51)` = go to parent. Rename via F2/Fn+Delete(`keyCode 117`).
- **TC classic colors.** Focus row navy `#000080` + white text; marked files blue `#0000FF`; directory names bold. Base background follows system light/dark (the view layer reads `effectiveAppearance`).
- **Delete (F8) → macOS trash** via `NSWorkspace.recycle`, handled in the AppKit layer (not the core engine), async with a main-thread reload on completion.
- **Command flow.** `NSEvent` → AppKit `KeyDispatcher` → `CommandID` → core `CommandRouter.execute` → core state change → callback → AppKit reload. Rename/mkdir/new-name prompts and the conflict prompt and trash are provided by the AppKit layer via injected closures on the router.

---

## File Structure

```
fly_commander/
├─ Package.swift                      # root package: TCCore / FlyCommander / TCCoreTests
├─ .gitignore
├─ Sources/
│  ├─ TCCore/
│  │  ├─ TCError.swift                # error normalization (Task 2)
│  │  ├─ Path/TCPath.swift            # path wrapper (Task 3)
│  │  ├─ Model/FileItem.swift         # one listing entry (Task 4)
│  │  ├─ Model/FileVisualRole.swift   # role + visualRole() (Task 4)
│  │  ├─ Sources/FileSource.swift     # protocol (Task 5)
│  │  ├─ Sources/LocalFileSource.swift# FileManager impl (Task 5)
│  │  ├─ Model/DirectoryPage.swift    # a loaded directory page (Task 6)
│  │  ├─ Selection/SelectionModel.swift # selection state machine (Task 6)
│  │  ├─ Focus/FilePane.swift         # per-pane state (Task 7)
│  │  ├─ Focus/Workspace.swift        # two panes + active + operation state (Task 7)
│  │  ├─ Operations/ConflictChoice.swift # conflict prompt types (Task 8)
│  │  ├─ Operations/OperationEngine.swift  # copy/move/rename/mkdir (Task 8)
│  │  ├─ Commands/CommandID.swift     # command enum (Task 8)
│  │  └─ Commands/CommandRouter.swift # central dispatcher (Task 8)
│  └─ FlyCommander/
│     ├─ main.swift                   # NSApplication bootstrap (Task 1, finalized Task 14)
│     ├─ App/AppDelegate.swift        # (Task 14)
│     ├─ App/MainWindowController.swift # (Task 14)
│     ├─ App/MainViewController.swift # glue: owns core, builds layout, wires events (Task 14)
│     ├─ Support/KeyDispatcher.swift  # NSEvent->CommandID (Task 9)
│     ├─ Panes/PaneColor.swift        # role->NSColor (Task 10)
│     ├─ Panes/FileItemCellView.swift # collection cell, 3 columns (Task 11)
│     ├─ Panes/FileCollectionView.swift # mouseDown->index (Task 12)
│     ├─ Panes/PaneView.swift         # pane container + data source/delegate + keys (Task 12)
│     ├─ Bars/CommandBar.swift        # bottom command-line row (Task 13)
│     └─ Bars/StatusBar.swift         # disk + selection row (Task 13)
├─ Tests/
│  └─ TCCoreTests/
│     ├─ TCErrorTests.swift           # (Task 2)
│     ├─ TCPathTests.swift            # (Task 3)
│     ├─ FileVisualRoleTests.swift    # (Task 4)
│     ├─ LocalFileSourceTests.swift   # (Task 5)
│     ├─ SelectionModelTests.swift    # (Task 6)
│     ├─ FilePaneTests.swift          # (Task 7)
│     ├─ OperationEngineTests.swift   # (Task 8)
│     └─ CommandRouterTests.swift     # (Task 8)
└─ README.md                          # run instructions + auth notes (Task 15)
```

---

### Task 1: SPM package scaffold

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/FlyCommander/main.swift`

**Interfaces:**
- Produces: package targets `TCCore` (library), `FlyCommander` (executable), `TCCoreTests`. (The original placeholder `public enum TCCore {}` was REMOVED post-Task 1 — commit 388f9cc: an umbrella enum named `TCCore` shadows the module name, breaking all `TCCore.X` qualified references from the app target. Real symbols from Tasks 2+ make the placeholder moot; library loadability is implied by every `@testable import TCCore` test.)

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlyCommander",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TCCore", targets: ["TCCore"]),
        .executable(name: "FlyCommander", targets: ["FlyCommander"]),
    ],
    targets: [
        .target(name: "TCCore"),
        .executableTarget(name: "FlyCommander",
                          dependencies: ["TCCore"]),
        .testTarget(name: "TCCoreTests",
                    dependencies: ["TCCore"]),
    ]
)
```

- [ ] **Step 2: Write `.gitignore`**

```text
.build/
.swiftpm/
DerivedData/
xcuserdata/
*.xcodeproj
```

- [x] **Step 3 (REMOVED post-Task 1):** Do NOT create `Sources/TCCore/TCCore.swift`. The placeholder `public enum TCCore {}` was removed (commit 388f9cc) because it shadowed the module name and broke `TCCore.X` qualified references in the app target. The library needs no placeholder symbol.

- [ ] **Step 4: Write `Sources/FlyCommander/main.swift`** (minimal bootstrap proving AppKit runs; replaced/extended in Task 14)

```swift
import AppKit

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                      styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
window.title = "FlyCommander"
let label = NSTextField(labelWithString: "FlyCommander skeleton")
label.frame = NSRect(x: 40, y: 110, width: 400, height: 20)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
```

- [x] **Step 5 (REMOVED post-Task 1):** Do NOT create `Tests/TCCoreTests/SmokeTests.swift`. Its only assertion (`XCTAssertEqual(TCCore.name, "TCCore")`) tested the removed umbrella enum; library loadability is covered by every subsequent `@testable import TCCore` test compiling.

- [ ] **Step 6: Build and test**

Run: `swift build && swift test`
Expected: build succeeds; `swift test` passes (no TCCore test cases yet — TCCoreTests gains real tests from Task 2 onward; the former smoke test was removed with the umbrella enum, see Step 5 note).

- [ ] **Step 7: Run the app skeleton**

Run: `swift run FlyCommander` (then quit the window)
Expected: a titled "FlyCommander" window appears with the label.

- [ ] **Step 8: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "chore: scaffold SPM package (TCCore + FlyCommander + tests)"
```

---

### Task 2: TCError + normalization

**Files:**
- Create: `Sources/TCCore/TCError.swift`
- Test: `Tests/TCCoreTests/TCErrorTests.swift`

**Interfaces:**
- Produces: `public enum TCError: Error, Equatable` with cases `.notFound(String)`, `.permissionDenied(String)`, `.busy(String)`, `.invalidPath(String)`, `.cancelled`, `.unknown(String)` and `var message: String`. `public func asTCError(_ error: Error) -> TCError`.

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/TCErrorTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class TCErrorTests: XCTestCase {
    func testMessageForNotFound() {
        XCTAssertEqual(TCError.notFound("/a").message, "找不到：/a")
    }
    func testMessageForCancelled() {
        XCTAssertEqual(TCError.cancelled.message, "已取消")
    }
    func testPassthrough() {
        XCTAssertEqual(asTCError(TCError.busy("/x")), TCError.busy("/x"))
    }
    func testMapsNoSuchFile() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        if case .notFound = asTCError(err) {
            // expected
        } else {
            XCTFail("expected .notFound, got \(asTCError(err))")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TCErrorTests`
Expected: FAIL (compiler error: `TCError` not found).

- [ ] **Step 3: Write `Sources/TCCore/TCError.swift`**

```swift
import Foundation

public enum TCError: Error, Equatable {
    case notFound(String)
    case permissionDenied(String)
    case busy(String)
    case invalidPath(String)
    case cancelled
    case unknown(String)

    public var message: String {
        switch self {
        case .notFound(let p): return "找不到：\(p)"
        case .permissionDenied(let p): return "没有权限访问：\(p)"
        case .busy(let p): return "忙碌/被占用：\(p)"
        case .invalidPath(let p): return "无效路径：\(p)"
        case .cancelled: return "已取消"
        case .unknown(let m): return m
        }
    }
}

public func asTCError(_ error: Error) -> TCError {
    if let e = error as? TCError { return e }
    let ns = error as NSError
    switch ns.code {
    case NSFileNoSuchFileError:
        return .notFound(ns.localizedDescription)
    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
        return .permissionDenied(ns.localizedDescription)
    case NSFileReadInvalidFileNameError, NSFileReadUnknownError:
        return .invalidPath(ns.localizedDescription)
    default:
        return .unknown(ns.localizedDescription)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TCErrorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TCCore/TCError.swift Tests/TCCoreTests/TCErrorTests.swift
git commit -m "feat(core): add TCError and asTCError normalization"
```

---

### Task 3: TCPath

**Files:**
- Create: `Sources/TCCore/Path/TCPath.swift`
- Test: `Tests/TCCoreTests/TCPathTests.swift`

**Interfaces:**
- Produces: `public struct TCPath: Hashable, Equatable` with `init(url: URL)`, `init(_ string: String)`, `let url: URL`, `var pathString: String`, `var fileName: String`, `var isRoot: Bool`, `var isHidden: Bool`, `var parent: TCPath?`, `func joining(_ name: String) -> TCPath`, `func displayString() -> String` (renders `$HOME` as `~`).

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/TCPathTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class TCPathTests: XCTestCase {
    func testParentOfNested() {
        let p = TCPath("/a/b/c")
        XCTAssertEqual(p.parent?.pathString, "/a/b")
    }
    func testRootHasNoParent() {
        XCTAssertEqual(TCPath("/").parent, nil)
    }
    func testJoining() {
        XCTAssertEqual(TCPath("/a/b").joining("c").pathString, "/a/b/c")
    }
    func testIsHiddenDotfile() {
        XCTAssertTrue(TCPath("/a/.zshrc").isHidden)
        XCTAssertFalse(TCPath("/a/file").isHidden)
    }
    func testTildeExpansion() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let p = TCPath("~/dev")
        XCTAssertEqual(p.pathString, home.appendingPathComponent("dev").path)
    }
    func testDisplayStringUsesTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(TCPath(home + "/dev").displayString(), "~/dev")
        XCTAssertEqual(TCPath(home).displayString(), "~")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TCPathTests`
Expected: FAIL (`TCPath` not found).

- [ ] **Step 3: Write `Sources/TCCore/Path/TCPath.swift`**

```swift
import Foundation

public struct TCPath: Hashable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public init(_ string: String) {
        var s = string
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s == "~" {
            s = home
        } else if s.hasPrefix("~/") {
            s = home + s.dropFirst(1)   // drop "~", keep "/..."
        }
        self.url = URL(fileURLWithPath: s).standardizedFileURL
    }

    public var pathString: String { url.path }
    public var fileName: String { url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
    public var isRoot: Bool { url.path == "/" }
    public var isHidden: Bool { url.lastPathComponent.hasPrefix(".") }
    public var parent: TCPath? { isRoot ? nil : TCPath(url: url.deletingLastPathComponent()) }

    @discardableResult
    public func joining(_ name: String) -> TCPath { TCPath(url: url.appendingPathComponent(name)) }

    public func displayString() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TCPathTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TCCore/Path/TCPath.swift Tests/TCCoreTests/TCPathTests.swift
git commit -m "feat(core): add TCPath path wrapper"
```

---

### Task 4: FileItem + FileVisualRole

**Files:**
- Create: `Sources/TCCore/Model/FileItem.swift`
- Create: `Sources/TCCore/Model/FileVisualRole.swift`
- Test: `Tests/TCCoreTests/FileVisualRoleTests.swift`

**Interfaces:**
- Produces: `public struct FileItem: Identifiable, Hashable, Equatable` (`id`, `path`, `name`, `isDirectory`, `size: Int64`, `modificationDate: Date`, `isHidden`, `isReadOnly`, `isExecutable`). `public enum FileVisualRole: Equatable` (`.normal`, `.directory`, `.marked`, `.focus`, `.hidden`, `.readOnly`). `public func visualRole(for item: FileItem, isMarked: Bool, isFocus: Bool) -> FileVisualRole` with precedence focus > marked > hidden > readOnly > directory > normal.

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/FileVisualRoleTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

func makeItem(name: String, isDir: Bool = false, hidden: Bool = false, readOnly: Bool = false) -> FileItem {
    FileItem(id: "/d/" + name, path: TCPath("/d/" + name), name: name, isDirectory: isDir,
             size: isDir ? 0 : 10, modificationDate: .distantPast,
             isHidden: hidden, isReadOnly: readOnly, isExecutable: false)
}

final class FileVisualRoleTests: XCTestCase {
    func testFocusWins() {
        XCTAssertEqual(visualRole(for: makeItem(name: "x", isDir: true), isMarked: true, isFocus: true), .focus)
    }
    func testMarkedBeatsDirectory() {
        XCTAssertEqual(visualRole(for: makeItem(name: "d", isDir: true), isMarked: true, isFocus: false), .marked)
    }
    func testHiddenBeatsDirectory() {
        XCTAssertEqual(visualRole(for: makeItem(name: ".d", isDir: true, hidden: true), isMarked: false, isFocus: false), .hidden)
    }
    func testReadOnly() {
        XCTAssertEqual(visualRole(for: makeItem(name: "r", readOnly: true), isMarked: false, isFocus: false), .readOnly)
    }
    func testDirectoryBoldRole() {
        XCTAssertEqual(visualRole(for: makeItem(name: "d", isDir: true), isMarked: false, isFocus: false), .directory)
    }
    func testNormal() {
        XCTAssertEqual(visualRole(for: makeItem(name: "f"), isMarked: false, isFocus: false), .normal)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FileVisualRoleTests`
Expected: FAIL (`FileItem` / `visualRole` not found).

- [ ] **Step 3: Write `Sources/TCCore/Model/FileItem.swift`**

```swift
import Foundation

public struct FileItem: Identifiable, Hashable, Equatable {
    public let id: String
    public let path: TCPath
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date
    public let isHidden: Bool
    public let isReadOnly: Bool
    public let isExecutable: Bool

    public init(id: String, path: TCPath, name: String, isDirectory: Bool, size: Int64,
                modificationDate: Date, isHidden: Bool, isReadOnly: Bool, isExecutable: Bool) {
        self.id = id
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.isHidden = isHidden
        self.isReadOnly = isReadOnly
        self.isExecutable = isExecutable
    }
}
```

- [ ] **Step 4: Write `Sources/TCCore/Model/FileVisualRole.swift`**

```swift
import Foundation

public enum FileVisualRole: Equatable {
    case normal, directory, marked, focus, hidden, readOnly
}

public func visualRole(for item: FileItem, isMarked: Bool, isFocus: Bool) -> FileVisualRole {
    if isFocus { return .focus }
    if isMarked { return .marked }
    if item.isHidden { return .hidden }
    if item.isReadOnly { return .readOnly }
    if item.isDirectory { return .directory }
    return .normal
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FileVisualRoleTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/TCCore/Model Tests/TCCoreTests/FileVisualRoleTests.swift
git commit -m "feat(core): add FileItem and FileVisualRole with precedence"
```

---

### Task 5: FileSource + LocalFileSource

**Files:**
- Create: `Sources/TCCore/Sources/FileSource.swift`
- Create: `Sources/TCCore/Sources/LocalFileSource.swift`
- Test: `Tests/TCCoreTests/LocalFileSourceTests.swift`

**Interfaces:**
- Consumes: `TCPath`, `FileItem`, `asTCError`.
- Produces: `public protocol FileSource { func listDirectory(_ path: TCPath) throws -> [FileItem]; func isDirectory(_ path: TCPath) -> Bool }` and `public struct LocalFileSource: FileSource`. `listDirectory` returns directories-first, then name-sorted; directories have `size == 0`.

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/LocalFileSourceTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class LocalFileSourceTests: XCTestCase {
    private let src = LocalFileSource()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testListsDirectoriesFirstThenFilesSorted() throws {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("zeta_dir"), withIntermediateDirectories: false)
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("alpha").path, contents: Data([1]))
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("beta").path, contents: Data([1, 2]))
        let items = try src.listDirectory(TCPath(url: tmp))
        let names = items.map { $0.name }
        XCTAssertEqual(names.first, "zeta_dir")          // directory first
        XCTAssertEqual(Array(names.dropFirst()), ["alpha", "beta"]) // localized case-insensitive order
        XCTAssertEqual(items[0].isDirectory, true)
        XCTAssertEqual(items[0].size, 0)
    }

    func testFileSize() throws {
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("f").path, contents: Data(count: 42))
        let items = try src.listDirectory(TCPath(url: tmp))
        XCTAssertEqual(items[0].size, 42)
    }

    func testNonDirectoryThrows() {
        let file = tmp.appendingPathComponent("leaf")
        try? FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try src.listDirectory(TCPath(url: file)))
    }

    func testIsDirectory() {
        XCTAssertTrue(src.isDirectory(TCPath(url: tmp)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LocalFileSourceTests`
Expected: FAIL (`LocalFileSource` not found).

- [ ] **Step 3: Write `Sources/TCCore/Sources/FileSource.swift`**

```swift
import Foundation

public protocol FileSource {
    func listDirectory(_ path: TCPath) throws -> [FileItem]
    func isDirectory(_ path: TCPath) -> Bool
}
```

- [ ] **Step 4: Write `Sources/TCCore/Sources/LocalFileSource.swift`**

```swift
import Foundation

public struct LocalFileSource: FileSource {
    public init() {}

    private let fm = FileManager.default
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .isHiddenKey, .isWritableKey, .isExecutableKey,
    ]

    public func isDirectory(_ path: TCPath) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path.url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func listDirectory(_ path: TCPath) throws -> [FileItem] {
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: path.url,
                                              includingPropertiesForKeys: Array(keys),
                                              options: [])
        } catch {
            throw asTCError(error)
        }
        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            let rv = (try? url.resourceValues(forKeys: keys)) ?? URLResourceValues()
            let isDir = rv.isDirectory ?? false
            let size: Int64 = isDir ? 0 : Int64(rv.fileSize ?? 0)
            let date = rv.contentModificationDate ?? .distantPast
            items.append(FileItem(
                id: url.path,
                path: TCPath(url: url),
                name: url.lastPathComponent,
                isDirectory: isDir,
                size: size,
                modificationDate: date,
                isHidden: rv.isHidden ?? false,
                isReadOnly: !(rv.isWritable ?? true),
                isExecutable: rv.isExecutable ?? false
            ))
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LocalFileSourceTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/TCCore/Sources Tests/TCCoreTests/LocalFileSourceTests.swift
git commit -m "feat(core): add FileSource protocol and LocalFileSource"
```

---

### Task 6: DirectoryPage + SelectionModel

**Files:**
- Create: `Sources/TCCore/Model/DirectoryPage.swift`
- Create: `Sources/TCCore/Selection/SelectionModel.swift`
- Test: `Tests/TCCoreTests/SelectionModelTests.swift`

**Interfaces:**
- Produces: `public struct DirectoryPage` (`path: TCPath`, `items: [FileItem]`, `hasMore: Bool = false`). `public struct SelectionModel: Equatable` with `enum MoveMode { case simple, additive, range }` and members/methods: `var items: [String]`, `var focusIndex: Int`, `var marked: Set<String>`, `func reload(with ids: [String])`, `var hasItems: Bool`, `var focusID: String?`, `func isMarked(_:) -> Bool`, `func isFocus(_:) -> Bool`, `var markedIDs: [String]`, `var operationIDs: [String]`, `mutating func moveFocus(to:mode:)`, `mutating func moveFocusBy(delta:mode:)`, `mutating func setFocus(to: Int)`, `mutating func toggleMark()`, `mutating func toggleMark(at: Int)`, `mutating func selectAll()`, `mutating func clearMarks()`.

Semantics: `.simple` moves focus and clears marks; `.additive` moves focus and adds the destination to marks; `.range` marks `[min(anchor,focus)..max(anchor,focus)]` inclusive, seeding `anchor` from the prior focus when unset; `operationIDs` = marked if any else the single focus id.

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/SelectionModelTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class SelectionModelTests: XCTestCase {
    func testSimpleMoveClearsMarks() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c", "d"])
        s.toggleMark()                       // marks "a"
        s.moveFocus(to: 2, mode: .simple)
        XCTAssertEqual(s.focusID, "c")
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testAdditiveMarksDestination() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c", "d"])
        s.moveFocusBy(delta: 1, mode: .additive)   // focus b, mark b
        XCTAssertEqual(s.focusID, "b")
        XCTAssertEqual(s.markedIDs, ["b"])
        s.moveFocusBy(delta: 1, mode: .additive)   // focus c, mark c
        XCTAssertEqual(s.markedIDs, ["b", "c"])
    }

    func testRangeSelectsInclusive() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c", "d", "e"])
        s.moveFocus(to: 1, mode: .simple)          // focus b, anchor unset
        s.moveFocus(to: 3, mode: .range)           // anchor=b(1), mark b,c,d
        XCTAssertEqual(s.markedIDs, ["b", "c", "d"])
    }

    func testToggleAt() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.toggleMark(at: 1)
        XCTAssertEqual(s.markedIDs, ["b"])
        s.toggleMark(at: 1)
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testOperationIDsFallbackToFocus() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.moveFocus(to: 1, mode: .simple)
        XCTAssertEqual(s.operationIDs, ["b"])
        s.toggleMark()
        XCTAssertEqual(s.operationIDs, ["b"])
    }

    func testSelectAllAndClear() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.selectAll()
        XCTAssertEqual(s.markedIDs, ["a", "b", "c"])
        s.clearMarks()
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testReloadResets() {
        var s = SelectionModel()
        s.reload(with: ["a", "b"])
        s.moveFocus(to: 1, mode: .simple)
        s.reload(with: ["x"])
        XCTAssertEqual(s.focusIndex, 0)
        XCTAssertEqual(s.focusID, "x")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SelectionModelTests`
Expected: FAIL (`SelectionModel` not found).

- [ ] **Step 3: Write `Sources/TCCore/Model/DirectoryPage.swift`**

```swift
import Foundation

public struct DirectoryPage {
    public let path: TCPath
    public let items: [FileItem]
    public let hasMore: Bool

    public init(path: TCPath, items: [FileItem], hasMore: Bool = false) {
        self.path = path
        self.items = items
        self.hasMore = hasMore
    }
}
```

- [ ] **Step 4: Write `Sources/TCCore/Selection/SelectionModel.swift`**

```swift
import Foundation

public struct SelectionModel: Equatable {
    public enum MoveMode: Equatable { case simple, additive, range }

    private(set) public var items: [String] = []
    private(set) public var focusIndex: Int = 0
    private(set) public var marked: Set<String> = []
    private var anchor: Int?

    public init() {}

    public mutating func reload(with ids: [String]) {
        items = ids
        focusIndex = 0
        marked = []
        anchor = nil
    }

    public var hasItems: Bool { !items.isEmpty }
    public var focusID: String? { items.indices.contains(focusIndex) ? items[focusIndex] : nil }

    public func isMarked(_ id: String) -> Bool { marked.contains(id) }
    public func isFocus(_ id: String) -> Bool { id == focusID }

    public var markedIDs: [String] { items.filter { marked.contains($0) } }
    public var operationIDs: [String] { markedIDs.isEmpty ? (focusID.map { [$0] } ?? []) : markedIDs }

    public mutating func moveFocus(to target: Int, mode: MoveMode) {
        guard hasItems else { return }
        let clamped = min(max(target, 0), items.count - 1)
        let oldFocus = focusIndex
        switch mode {
        case .simple:
            focusIndex = clamped
            marked = []
            anchor = nil
        case .additive:
            marked.insert(items[clamped])
            focusIndex = clamped
        case .range:
            if anchor == nil { anchor = oldFocus }
            let a = anchor!
            for i in min(a, clamped)...max(a, clamped) { marked.insert(items[i]) }
            focusIndex = clamped
        }
    }

    public mutating func moveFocusBy(delta: Int, mode: MoveMode) {
        moveFocus(to: focusIndex + delta, mode: mode)
    }

    public mutating func setFocus(to index: Int) {
        guard hasItems else { return }
        focusIndex = min(max(index, 0), items.count - 1)
    }

    public mutating func toggleMark() {
        guard let id = focusID else { return }
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
    }

    public mutating func toggleMark(at index: Int) {
        guard items.indices.contains(index) else { return }
        let id = items[index]
        if marked.contains(id) { marked.remove(id) } else { marked.insert(id) }
    }

    public mutating func selectAll() { marked = Set(items) }
    public mutating func clearMarks() { marked = []; anchor = nil }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SelectionModelTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/TCCore/Model/DirectoryPage.swift Sources/TCCore/Selection/SelectionModel.swift Tests/TCCoreTests/SelectionModelTests.swift
git commit -m "feat(core): add DirectoryPage and SelectionModel state machine"
```

---

### Task 7: FilePane + Workspace

**Files:**
- Create: `Sources/TCCore/Focus/FilePane.swift`
- Create: `Sources/TCCore/Focus/Workspace.swift`
- Test: `Tests/TCCoreTests/FilePaneTests.swift`

**Interfaces:**
- Consumes: `TCPath`, `FileItem`, `DirectoryPage`, `SelectionModel`, `FileSource`.
- Produces:
  - `public enum PaneID: Equatable { case left, right }`
  - `public final class FilePane` with `let id: PaneID`, `private(set) var path: TCPath`, `private(set) var selection: SelectionModel`, `private(set) var page: DirectoryPage?`, `var onReload: ((FilePane) -> Void)?`; `init(id:source:startPath:)`; `var itemByID: [String: FileItem]`; `var operationTargets: [FileItem]`; `var focusedItem: FileItem?`; `var itemCount: Int`; `func load()`; `func navigate(to: TCPath)`; `func enterFocusedDirectory()`; `func gotoParent()`; `func moveFocus(to:mode:)`; `func moveFocusBy(delta:mode:)`; `func setFocus(to:)`; `func toggleMark()`; `func toggleMark(at:)`; `func selectAll()`; `func clearMarks()`.
  - `public enum OperationState: Equatable { case idle, running(label: String, progress: Double), done(String), failed(String) }`
  - `public final class Workspace` with `let left/right: FilePane`, `private(set) var active: PaneID`, `var onActiveChange: ((Workspace) -> Void)?`, `var onOperationState: ((OperationState) -> Void)?`, `init(left:right:active:)`, `var activePane: FilePane`, `var inactivePane: FilePane`, `func activate(_:)`, `func switchActive()`, `func operationState(_:)`.

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/FilePaneTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class FilePaneTests: XCTestCase {
    private let source = LocalFileSource()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pane_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("dir1"), withIntermediateDirectories: false)
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("file.txt").path, contents: Data([1,2,3]))
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoadPopulatesItemsAndSelection() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        var fired = 0
        pane.onReload = { _ in fired += 1 }
        pane.load()
        XCTAssertEqual(pane.itemCount, 2)                 // dir1, file.txt
        XCTAssertEqual(pane.selection.focusIndex, 0)
        XCTAssertEqual(pane.page?.items.first?.name, "dir1")
        XCTAssertEqual(fired, 1)
    }

    func testNavigateAndParent() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 0, mode: .simple)              // focus dir1
        pane.enterFocusedDirectory()
        XCTAssertEqual(pane.path.url.lastPathComponent, "dir1")
        pane.gotoParent()
        XCTAssertEqual(pane.path.url.lastPathComponent, tmp.lastPathComponent)
    }

    func testOperationTargetsUsesSelection() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 1, mode: .simple)              // focus file.txt
        XCTAssertEqual(pane.operationTargets.map { $0.name }, ["file.txt"])
        pane.toggleMark()                                  // mark file.txt
        pane.moveFocus(to: 0, mode: .additive)            // focus+mark dir1
        XCTAssertEqual(Set(pane.operationTargets.map { $0.name }), ["dir1", "file.txt"])
    }

    func testWorkspaceSwitchActive() {
        let a = FilePane(id: .left, source: source, startPath: TCPath("~"))
        let b = FilePane(id: .right, source: source, startPath: TCPath("~"))
        let ws = Workspace(left: a, right: b, active: .left)
        var fired = 0
        ws.onActiveChange = { _ in fired += 1 }
        XCTAssertEqual(ws.active, .left)
        ws.switchActive()
        XCTAssertEqual(ws.active, .right)
        XCTAssert(ws.activePane === b)
        XCTAssert(ws.inactivePane === a)
        XCTAssertEqual(fired, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FilePaneTests`
Expected: FAIL (`FilePane` not found).

- [ ] **Step 3: Write `Sources/TCCore/Focus/FilePane.swift`**

```swift
import Foundation

public enum PaneID: Equatable { case left, right }

public final class FilePane {
    public let id: PaneID
    private let source: FileSource
    public private(set) var path: TCPath
    public private(set) var selection = SelectionModel()
    public private(set) var page: DirectoryPage?

    public var onReload: ((FilePane) -> Void)?

    public init(id: PaneID, source: FileSource, startPath: TCPath) {
        self.id = id
        self.source = source
        self.path = startPath
    }

    public var itemByID: [String: FileItem] {
        guard let page else { return [:] }
        return Dictionary(uniqueKeysWithValues: page.items.map { ($0.id, $0) })
    }

    public var operationTargets: [FileItem] {
        let byID = itemByID
        return selection.operationIDs.compactMap { byID[$0] }
    }

    public var focusedItem: FileItem? { selection.focusID.flatMap { itemByID[$0] } }
    public var itemCount: Int { page?.items.count ?? 0 }

    public func load() {
        do {
            let items = try source.listDirectory(path)
            let page = DirectoryPage(path: path, items: items)
            self.page = page
            selection.reload(with: items.map { $0.id })
        } catch {
            self.page = DirectoryPage(path: path, items: [])
            selection.reload(with: [])
        }
        onReload?(self)
    }

    public func navigate(to newPath: TCPath) {
        guard newPath.isRoot || source.isDirectory(newPath) else { return }
        path = newPath
        load()
    }

    public func enterFocusedDirectory() {
        if let item = focusedItem, item.isDirectory { navigate(to: item.path) }
    }

    public func gotoParent() {
        if let p = path.parent { navigate(to: p) }
    }

    public func moveFocus(to index: Int, mode: SelectionModel.MoveMode) {
        selection.moveFocus(to: index, mode: mode)
        onReload?(self)
    }
    public func moveFocusBy(delta: Int, mode: SelectionModel.MoveMode) {
        selection.moveFocusBy(delta: delta, mode: mode)
        onReload?(self)
    }
    public func setFocus(to index: Int) { selection.setFocus(to: index); onReload?(self) }
    public func toggleMark() { selection.toggleMark(); onReload?(self) }
    public func toggleMark(at index: Int) { selection.toggleMark(at: index); onReload?(self) }
    public func selectAll() { selection.selectAll(); onReload?(self) }
    public func clearMarks() { selection.clearMarks(); onReload?(self) }
}
```

- [ ] **Step 4: Write `Sources/TCCore/Focus/Workspace.swift`**

```swift
import Foundation

public enum OperationState: Equatable {
    case idle
    case running(label: String, progress: Double)
    case done(String)
    case failed(String)
}

public final class Workspace {
    public let left: FilePane
    public let right: FilePane
    public private(set) var active: PaneID

    public var onActiveChange: ((Workspace) -> Void)?
    public var onOperationState: ((OperationState) -> Void)?

    public init(left: FilePane, right: FilePane, active: PaneID = .left) {
        self.left = left
        self.right = right
        self.active = active
    }

    public var activePane: FilePane { active == .left ? left : right }
    public var inactivePane: FilePane { active == .left ? right : left }

    public func activate(_ id: PaneID) {
        guard active != id else { return }
        active = id
        onActiveChange?(self)
    }

    public func switchActive() { activate(active == .left ? .right : .left) }

    public func operationState(_ s: OperationState) { onOperationState?(s) }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter FilePaneTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/TCCore/Focus Tests/TCCoreTests/FilePaneTests.swift
git commit -m "feat(core): add FilePane and Workspace"
```

---

### Task 8: ConflictChoice + OperationEngine + CommandRouter

**Files:**
- Create: `Sources/TCCore/Operations/ConflictChoice.swift`
- Create: `Sources/TCCore/Operations/OperationEngine.swift`
- Create: `Sources/TCCore/Commands/CommandID.swift`
- Create: `Sources/TCCore/Commands/CommandRouter.swift`
- Test: `Tests/TCCoreTests/OperationEngineTests.swift`
- Test: `Tests/TCCoreTests/CommandRouterTests.swift`

**Interfaces:**
- Produces:
  - `public enum ConflictChoice: Equatable { case overwrite, skip, overwriteAll, skipAll, cancel }` and `public typealias ConflictPrompt = (_ source: TCPath, _ destination: TCPath) -> ConflictChoice`.
  - `public final class OperationEngine` with `init(fileManager:)` and `performCopy(_:to:prompt:progress:) throws`, `performMove(_:to:prompt:progress:) throws`, `performRename(_:to:) throws`, `performMakeDirectory(_:in:) throws -> TCPath`.
  - `public enum CommandID: Hashable` (`.up, .down, .pageUp, .pageDown, .home, .end, .enter, .parent, .switchPane, .toggleMark, .selectAll, .clearMarks, .copy, .move, .delete, .rename, .makeDirectory, .cancel`).
  - `public final class CommandRouter` with `let workspace: Workspace`, `let engine: OperationEngine`, `var conflictPrompt: ConflictPrompt?`, `var onDelete: ((FilePane, [FileItem]) -> Void)?`, `init(workspace:engine:)`, `func execute(_ id: CommandID, moveMode: SelectionModel.MoveMode = .simple)`, `func rename(to: String)`, `func makeDirectory(named: String)`.

Behavior: copy/move write to the **inactive** pane's directory; conflict prompt is consulted per existing destination and honors `overwriteAll`/`skipAll`/`cancel` (`.cancel` throws `TCError.cancelled`; a real error mid-move rolls back already-moved items). `execute(.copy/.move)` sets `running`/`done`/`failed` operation state, reloads both panes; `execute(.delete)` delegates to `onDelete`.

- [ ] **Step 1: Write the failing test `Tests/TCCoreTests/OperationEngineTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class OperationEngineTests: XCTestCase {
    private let engine = OperationEngine()
    private var src: URL!
    private var dst: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("op_\(UUID().uuidString)")
        src = base.appendingPathComponent("src")
        dst = base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: src.deletingLastPathComponent())
    }

    private func copyTargets(_ dir: URL) throws -> [FileItem] {
        try LocalFileSource().listDirectory(TCPath(url: dir))
    }

    func testCopyCreatesDestinations() throws {
        try engine.performCopy(try copyTargets(src), to: TCPath(url: dst))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("sub").path))
    }

    func testCopySkipAll() throws {
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try engine.performCopy(try copyTargets(src), to: TCPath(url: dst)) { _, _ in .skipAll }
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "old")
    }

    func testCopyOverwrite() throws {
        try "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try engine.performCopy(try copyTargets(src), to: TCPath(url: dst)) { _, _ in .overwrite }
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
    }

    func testCopyCancelThrows() {
        try? "old".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try engine.performCopy(try! copyTargets(src), to: TCPath(url: dst)) { _, _ in .cancel }) { error in
            XCTAssertEqual(error as? TCError, .cancelled)
        }
    }

    func testMoveRemovesSource() throws {
        try engine.performMove(try copyTargets(src), to: TCPath(url: dst))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
    }

    func testRename() throws {
        let items = try copyTargets(src)
        let a = items.first { $0.name == "a.txt" }!
        try engine.performRename(a, to: "renamed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("renamed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }

    func testMakeDirectory() throws {
        let newDir = try engine.performMakeDirectory("newd", in: TCPath(url: src))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDir.url.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter OperationEngineTests`
Expected: FAIL (`OperationEngine` not found).

- [ ] **Step 3: Write `Sources/TCCore/Operations/ConflictChoice.swift`**

```swift
import Foundation

public enum ConflictChoice: Equatable {
    case overwrite, skip, overwriteAll, skipAll, cancel
}

public typealias ConflictPrompt = (_ source: TCPath, _ destination: TCPath) -> ConflictChoice
```

- [ ] **Step 4: Write `Sources/TCCore/Operations/OperationEngine.swift`**

```swift
import Foundation

public final class OperationEngine {
    private let fm: FileManager
    public init(fileManager: FileManager = .default) { self.fm = fileManager }

    public func performCopy(_ items: [FileItem], to destDir: TCPath,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        let total = items.count
        for (i, item) in items.enumerated() {
            let src = item.path.url
            let dst = destDir.url.appendingPathComponent(item.name)
            var dstIsDir: ObjCBool = false
            let exists = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir)
            if exists {
                if skipAll { progress?(i + 1, total); continue }
                if overwriteAll {
                    do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                }
                else if let choice = prompt?(item.path, TCPath(url: dst)) {
                    switch choice {
                    case .overwrite:
                        do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                    case .overwriteAll:
                        overwriteAll = true
                        do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                    case .skip: progress?(i + 1, total); continue
                    case .skipAll: skipAll = true; progress?(i + 1, total); continue
                    case .cancel: throw TCError.cancelled
                    }
                } else {
                    do { try fm.removeItem(at: dst) } catch { throw asTCError(error) }
                }
            }
            do { try fm.copyItem(at: src, to: dst) } catch { throw asTCError(error) }
            progress?(i + 1, total)
        }
    }

    public func performMove(_ items: [FileItem], to destDir: TCPath,
                            prompt: ConflictPrompt? = nil,
                            progress: ((Int, Int) -> Void)? = nil) throws {
        var overwriteAll = false, skipAll = false
        var moved: [(from: URL, to: URL)] = []
        let total = items.count
        for (i, item) in items.enumerated() {
            let src = item.path.url
            let dst = destDir.url.appendingPathComponent(item.name)
            do {
                var dstIsDir: ObjCBool = false
                let exists = fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir)
                if exists {
                    if skipAll { progress?(i + 1, total); continue }
                    if overwriteAll {
                        try fm.removeItem(at: dst)
                    } else if let choice = prompt?(item.path, TCPath(url: dst)) {
                        switch choice {
                        case .overwrite:
                            try fm.removeItem(at: dst)
                        case .overwriteAll:
                            overwriteAll = true
                            try fm.removeItem(at: dst)
                        case .skip: progress?(i + 1, total); continue
                        case .skipAll: skipAll = true; progress?(i + 1, total); continue
                        case .cancel: throw TCError.cancelled
                        }
                    } else {
                        try fm.removeItem(at: dst)
                    }
                }
                try fm.moveItem(at: src, to: dst)
                moved.append((dst, src))
            } catch {
                if case TCError.cancelled = asTCError(error) { throw error }
                for pair in moved.reversed() { try? fm.moveItem(at: pair.from, to: pair.to) }
                throw asTCError(error)
            }
            progress?(i + 1, total)
        }
    }

    public func performRename(_ item: FileItem, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw TCError.invalidPath(newName) }
        guard let parent = item.path.parent else { throw TCError.invalidPath(item.path.pathString) }
        let dst = parent.url.appendingPathComponent(trimmed)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dst.path, isDirectory: &isDir) {
            throw TCError.unknown("已存在同名：\(trimmed)")
        }
        do { try fm.moveItem(at: item.path.url, to: dst) } catch { throw asTCError(error) }
    }

    @discardableResult
    public func performMakeDirectory(_ name: String, in dir: TCPath) throws -> TCPath {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { throw TCError.invalidPath(name) }
        let newDir = dir.joining(trimmed)
        do { try fm.createDirectory(at: newDir.url, withIntermediateDirectories: false) }
        catch { throw asTCError(error) }
        return newDir
    }
}
```

- [ ] **Step 5: Run OperationEngine tests to verify they pass**

Run: `swift test --filter OperationEngineTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Write `Sources/TCCore/Commands/CommandID.swift`**

```swift
import Foundation

public enum CommandID: Hashable {
    case up, down, pageUp, pageDown, home, end
    case enter, parent
    case switchPane
    case toggleMark, selectAll, clearMarks
    case copy, move, delete, rename, makeDirectory
    case cancel
}
```

- [ ] **Step 7: Write `Sources/TCCore/Commands/CommandRouter.swift`**

```swift
import Foundation

public final class CommandRouter {
    public let workspace: Workspace
    public let engine: OperationEngine
    public var conflictPrompt: ConflictPrompt?
    public var onDelete: ((FilePane, [FileItem]) -> Void)?

    public init(workspace: Workspace, engine: OperationEngine = OperationEngine()) {
        self.workspace = workspace
        self.engine = engine
    }

    public func execute(_ id: CommandID, moveMode: SelectionModel.MoveMode = .simple) {
        let a = workspace.activePane
        switch id {
        case .up: a.moveFocusBy(delta: -1, mode: moveMode)
        case .down: a.moveFocusBy(delta: 1, mode: moveMode)
        case .pageUp: a.moveFocusBy(delta: -15, mode: moveMode)
        case .pageDown: a.moveFocusBy(delta: 15, mode: moveMode)
        case .home: a.moveFocus(to: 0, mode: .simple)
        case .end: a.moveFocus(to: a.itemCount - 1, mode: .simple)
        case .enter: a.enterFocusedDirectory()
        case .parent: a.gotoParent()
        case .switchPane: workspace.switchActive()
        case .toggleMark: a.toggleMark()
        case .selectAll: a.selectAll()
        case .clearMarks, .cancel: a.clearMarks()
        case .copy: runTransfer(isCopy: true)
        case .move: runTransfer(isCopy: false)
        case .delete:
            let targets = a.operationTargets
            if !targets.isEmpty { onDelete?(a, targets) }
        case .rename: break
        case .makeDirectory: break
        }
    }

    public func rename(to newName: String) {
        guard let item = workspace.activePane.focusedItem else { return }
        workspace.operationState(.running(label: "重命名", progress: 0))
        do {
            try engine.performRename(item, to: newName)
            workspace.activePane.load()
            workspace.operationState(.done("已重命名"))
        } catch {
            workspace.activePane.load()
            workspace.operationState(.failed(error.localizedDescription))
        }
    }

    public func makeDirectory(named name: String) {
        let a = workspace.activePane
        workspace.operationState(.running(label: "新建目录", progress: 0))
        do {
            _ = try engine.performMakeDirectory(name, in: a.path)
            a.load()
            workspace.operationState(.done("已新建目录"))
        } catch {
            a.load()
            workspace.operationState(.failed(error.localizedDescription))
        }
    }

    private func runTransfer(isCopy: Bool) {
        let a = workspace.activePane
        let t = workspace.inactivePane
        let targets = a.operationTargets
        guard !targets.isEmpty else { return }
        let label = (isCopy ? "复制" : "移动") + " \(targets.count) 个文件"
        workspace.operationState(.running(label: label, progress: 0))
        do {
            if isCopy {
                try engine.performCopy(targets, to: t.path, prompt: conflictPrompt) { d, c in
                    workspace.operationState(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c)))
                }
            } else {
                try engine.performMove(targets, to: t.path, prompt: conflictPrompt) { d, c in
                    workspace.operationState(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c)))
                }
            }
            a.load()
            t.load()
            workspace.operationState(.done("\(label) 完成"))
        } catch let e as TCError {
            a.load()
            t.load()
            workspace.operationState(e == .cancelled ? .idle : .failed(e.message))
        } catch {
            a.load()
            t.load()
            workspace.operationState(.failed(error.localizedDescription))
        }
    }
}
```

- [ ] **Step 8: Write the failing test `Tests/TCCoreTests/CommandRouterTests.swift`**

```swift
import XCTest
import Foundation
@testable import TCCore

final class CommandRouterTests: XCTestCase {
    private var leftDir: URL!
    private var rightDir: URL!
    private var workspace: Workspace!
    private var router: CommandRouter!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rtr_\(UUID().uuidString)")
        leftDir = base.appendingPathComponent("L")
        rightDir = base.appendingPathComponent("R")
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)
        try "a".write(to: leftDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "z".write(to: leftDir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: TCPath(url: leftDir))
        let right = FilePane(id: .right, source: source, startPath: TCPath(url: rightDir))
        workspace = Workspace(left: left, right: right, active: .left)
        router = CommandRouter(workspace: workspace, engine: OperationEngine())
        left.load()
        right.load()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: leftDir.deletingLastPathComponent())
    }

    func testDownMovesFocus() {
        router.execute(.down, moveMode: .simple)
        XCTAssertEqual(workspace.activePane.selection.focusIndex, 1)
    }

    func testCopyToInactivePane() {
        router.execute(.copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
    }

    func testMoveToInactivePane() {
        router.execute(.move)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("a.txt").path))
    }

    func testRenameViaMethod() {
        workspace.activePane.moveFocus(to: 0, mode: .simple)
        router.rename(to: "changed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("changed.txt").path))
    }

    func testMakeDirectoryViaMethod() {
        router.makeDirectory(named: "newdir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("newdir").path))
    }

    func testDeleteDelegatesToOnDelete() {
        var got: [FileItem] = []
        router.onDelete = { _, items in got = items }
        router.execute(.delete)
        XCTAssertEqual(got.map { $0.name }, ["a.txt"])
    }

    func testOperationStateEmittedOnCopy() {
        var last: OperationState?
        workspace.onOperationState = { last = $0 }
        router.execute(.copy)
        if case .done = last {
            // expected
        } else {
            XCTFail("expected .done, got \(String(describing: last))")
        }
    }
}
```

- [ ] **Step 9: Run CommandRouter tests to verify they pass**

Run: `swift test --filter CommandRouterTests`
Expected: PASS (7 tests).

- [ ] **Step 10: Run the full core suite**

Run: `swift test`
Expected: all `TCCoreTests` pass.

- [ ] **Step 11: Commit**

```bash
git add Sources/TCCore/Operations Sources/TCCore/Commands Tests/TCCoreTests/OperationEngineTests.swift Tests/TCCoreTests/CommandRouterTests.swift
git commit -m "feat(core): add OperationEngine, CommandID, and CommandRouter"
```

---

### Task 9: KeyDispatcher (AppKit)

**Files:**
- Create: `Sources/FlyCommander/Support/KeyDispatcher.swift`
- Test: `Tests/TCCoreTests/KeyDispatcherTests.swift` (a test target may import the app module only if it is a product; to keep the test target isolated to `TCCore`, we instead place this test as a small executable-free check — **see Step 1 note**.)

**Interfaces:**
- Consumes: `TCCore.CommandID`, `TCCore.SelectionModel.MoveMode`.
- Produces: `struct KeyInput { let keyCode: UInt16; let modifiers: NSEvent.ModifierFlags }`, `struct DispatchResult { let command: TCCore.CommandID; let moveMode: SelectionModel.MoveMode }`, `enum KeyDispatcher { static func dispatch(_ input: KeyInput) -> DispatchResult? }`.

> **Note:** `KeyDispatcher` lives in the `FlyCommander` (AppKit) target, so it cannot be imported by `TCCoreTests`. We verify its pure logic by making the mapping a static function and testing it through a tiny **AppKit** test target is not set up here; instead we keep the mapping small and verify it manually in Task 15. To still get automated coverage, add a second test target for the app module in this task.

- [ ] **Step 1: Add an app test target to `Package.swift`**

Edit `Package.swift` to add the target and a product-independent test target. Replace the `targets:` array with:

```swift
    targets: [
        .target(name: "TCCore"),
        .executableTarget(name: "FlyCommander",
                          dependencies: ["TCCore"]),
        .testTarget(name: "TCCoreTests",
                    dependencies: ["TCCore"]),
        .testTarget(name: "FlyCommanderTests",
                    dependencies: ["FlyCommander"]),
    ]
```

- [ ] **Step 2: Write the failing test `Tests/FlyCommanderTests/KeyDispatcherTests.swift`** (new `Tests/FlyCommanderTests` directory)

```swift
import XCTest
import AppKit
@testable import FlyCommander

final class KeyDispatcherTests: XCTestCase {
    func testUpSimple() {
        let r = KeyDispatcher.dispatch(KeyInput(keyCode: 126, modifiers: []))
        XCTAssertEqual(r?.command, .up)
        XCTAssertEqual(r?.moveMode, .simple)
    }
    func testDownCtrlAdditive() {
        let r = KeyDispatcher.dispatch(KeyInput(keyCode: 125, modifiers: [.control]))
        XCTAssertEqual(r?.command, .down)
        XCTAssertEqual(r?.moveMode, .additive)
    }
    func testUpShiftRange() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 126, modifiers: [.shift]))?.moveMode, .range)
    }
    func testTabSwitchesPane() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 48, modifiers: []))?.command, .switchPane)
    }
    func testCtrlRightSwitchesPane() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 124, modifiers: [.control]))?.command, .switchPane)
    }
    func testLeftIsParent() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 123, modifiers: []))?.command, .parent)
    }
    func testF5Copy() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 96, modifiers: []))?.command, .copy)
    }
    func testF6Move() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 97, modifiers: []))?.command, .move)
    }
    func testF8Delete() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 99, modifiers: []))?.command, .delete)
    }
    func testCmdASelectAll() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 0, modifiers: [.command]))?.command, .selectAll)
    }
    func testOptionQToggle() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 12, modifiers: [.option]))?.command, .toggleMark)
    }
    func testUnknownReturnsNil() {
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 50, modifiers: [])))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter KeyDispatcherTests`
Expected: FAIL (`KeyDispatcher` not found).

- [ ] **Step 4: Write `Sources/FlyCommander/Support/KeyDispatcher.swift`**

```swift
import Foundation
import AppKit
import TCCore

struct KeyInput {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
}

struct DispatchResult {
    let command: CommandID
    let moveMode: SelectionModel.MoveMode
}

enum KeyDispatcher {
    static func dispatch(_ input: KeyInput) -> DispatchResult? {
        let m = input.modifiers.intersection([.command, .control, .option, .shift])
        func has(_ flags: NSEvent.ModifierFlags) -> Bool { m.contains(flags) }

        switch input.keyCode {
        case 126: // Up
            if has(.control) { return DispatchResult(command: .up, moveMode: .additive) }
            if has(.shift) { return DispatchResult(command: .up, moveMode: .range) }
            return DispatchResult(command: .up, moveMode: .simple)
        case 125: // Down
            if has(.control) { return DispatchResult(command: .down, moveMode: .additive) }
            if has(.shift) { return DispatchResult(command: .down, moveMode: .range) }
            return DispatchResult(command: .down, moveMode: .simple)
        case 123: // Left
            return has(.control) ? DispatchResult(command: .switchPane, moveMode: .simple)
                                 : DispatchResult(command: .parent, moveMode: .simple)
        case 124: // Right
            return has(.control) ? DispatchResult(command: .switchPane, moveMode: .simple)
                                 : DispatchResult(command: .enter, moveMode: .simple)
        case 116: return DispatchResult(command: .pageUp, moveMode: .simple)
        case 121: return DispatchResult(command: .pageDown, moveMode: .simple)
        case 115: return DispatchResult(command: .home, moveMode: .simple)
        case 119: return DispatchResult(command: .end, moveMode: .simple)
        case 36, 76: return DispatchResult(command: .enter, moveMode: .simple) // Return / numpad Enter
        case 48: return DispatchResult(command: .switchPane, moveMode: .simple) // Tab
        case 51: return DispatchResult(command: .parent, moveMode: .simple)    // Backspace/Delete
        case 117: return DispatchResult(command: .rename, moveMode: .simple)   // Fn+Delete
        case 49: return DispatchResult(command: .toggleMark, moveMode: .simple) // Space
        case 53: return DispatchResult(command: .clearMarks, moveMode: .simple) // Esc
        case 96: return DispatchResult(command: .copy, moveMode: .simple)       // F5
        case 97: return DispatchResult(command: .move, moveMode: .simple)       // F6
        case 98: return DispatchResult(command: .makeDirectory, moveMode: .simple) // F7
        case 99: return DispatchResult(command: .delete, moveMode: .simple)     // F8
        case 12: // Q
            return has(.option) ? DispatchResult(command: .toggleMark, moveMode: .simple) : nil
        case 0: // A
            return has(.command) ? DispatchResult(command: .selectAll, moveMode: .simple) : nil
        default: return nil
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter KeyDispatcherTests`
Expected: PASS (12 tests).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/FlyCommander/Support/KeyDispatcher.swift Tests/FlyCommanderTests/KeyDispatcherTests.swift
git commit -m "feat(app): add KeyDispatcher NSEvent->CommandID mapping"
```

---

### Task 10: PaneColor (role → NSColor)

**Files:**
- Create: `Sources/FlyCommander/Panes/PaneColor.swift`
- Test: `Tests/FlyCommanderTests/PaneColorTests.swift`

**Interfaces:**
- Consumes: `TCCore.FileVisualRole`.
- Produces: `enum PaneColor` with `static let navy: NSColor` (`#000080`), `static let markedBlue: NSColor` (`#0000FF`), `static func background(for:active:dark:) -> NSColor`, `static func text(for:dark:) -> NSColor`, `static func isBold(_ role: FileVisualRole) -> Bool`.

- [ ] **Step 1: Write the failing test `Tests/FlyCommanderTests/PaneColorTests.swift`**

```swift
import XCTest
import AppKit
import TCCore
@testable import FlyCommander

final class PaneColorTests: XCTestCase {
    func testFocusBackgroundIsNavy() {
        XCTAssertEqual(PaneColor.background(for: .focus, active: true, dark: false), PaneColor.navy)
    }
    func testNonFocusBackgroundClear() {
        XCTAssertEqual(PaneColor.background(for: .normal, active: true, dark: false), NSColor.clear)
    }
    func testMarkedTextIsBlue() {
        XCTAssertEqual(PaneColor.text(for: .marked, dark: true), PaneColor.markedBlue)
    }
    func testFocusTextIsWhite() {
        XCTAssertEqual(PaneColor.text(for: .focus, dark: false), NSColor.white)
    }
    func testDirectoryBold() {
        XCTAssertTrue(PaneColor.isBold(.directory))
        XCTAssertTrue(PaneColor.isBold(.focus))
        XCTAssertFalse(PaneColor.isBold(.normal))
    }
    func testHiddenTextGray() {
        XCTAssertEqual(PaneColor.text(for: .hidden, dark: false), NSColor.gray)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PaneColorTests`
Expected: FAIL (`PaneColor` not found).

- [ ] **Step 3: Write `Sources/FlyCommander/Panes/PaneColor.swift`**

```swift
import AppKit
import TCCore

enum PaneColor {
    static let navy = NSColor(red: 0.0, green: 0.0, blue: 80.0 / 255.0, alpha: 1.0)
    static let markedBlue = NSColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)

    static func background(for role: FileVisualRole, active: Bool, dark: Bool) -> NSColor {
        role == .focus ? navy : .clear
    }

    static func text(for role: FileVisualRole, dark: Bool) -> NSColor {
        switch role {
        case .focus: return .white
        case .marked: return markedBlue
        case .hidden, .readOnly: return .gray
        case .directory, .normal: return dark ? .white : .black
        }
    }

    static func isBold(_ role: FileVisualRole) -> Bool {
        role == .directory || role == .focus
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PaneColorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlyCommander/Panes/PaneColor.swift Tests/FlyCommanderTests/PaneColorTests.swift
git commit -m "feat(app): add PaneColor role->NSColor mapping (TC classic palette)"
```

---

### Task 11: FileItemCellView

**Files:**
- Create: `Sources/FlyCommander/Panes/FileItemCellView.swift`

**Interfaces:**
- Consumes: `TCCore.FileItem`, `TCCore.FileVisualRole`, `PaneColor`.
- Produces: `final class FileItemCellView: NSCollectionViewItem` with `func configure(with item: FileItem, role: FileVisualRole, dark: Bool)`. Renders three columns (name / size / date) and a background view for the focus row.

- [ ] **Step 1: Write `Sources/FlyCommander/Panes/FileItemCellView.swift`**

```swift
import AppKit
import TCCore

final class FileItemCellView: NSCollectionViewItem {
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let bgView = NSView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 20))
        self.view = container
        bgView.wantsLayer = true
        container.addSubview(bgView)
        container.addSubview(nameLabel)
        container.addSubview(sizeLabel)
        container.addSubview(dateLabel)

        nameLabel.font = .systemFont(ofSize: 12)
        sizeLabel.font = .systemFont(ofSize: 11)
        dateLabel.font = .systemFont(ofSize: 11)
        sizeLabel.alignment = .right

        bgView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: container.topAnchor),
            bgView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bgView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -6),

            sizeLabel.widthAnchor.constraint(equalToConstant: 90),
            sizeLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -6),
            sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            dateLabel.widthAnchor.constraint(equalToConstant: 150),
            dateLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            dateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    func configure(with item: FileItem, role: FileVisualRole, dark: Bool) {
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = item.isDirectory ? "" : ByteCountFormatter().string(fromByteCount: max(0, item.size))
        dateLabel.stringValue = item.modificationDate.formatted(date: .abbreviated, time: .shortened)

        let text = PaneColor.text(for: role, dark: dark)
        nameLabel.textColor = text
        sizeLabel.textColor = text.withAlphaComponent(0.7)
        dateLabel.textColor = text.withAlphaComponent(0.7)

        let bold = PaneColor.isBold(role)
        nameLabel.font = bold ? .systemFont(ofSize: 12, weight: .bold) : .systemFont(ofSize: 12)
        bgView.layer?.backgroundColor = PaneColor.background(for: role, active: true, dark: dark).cgColor
    }
}
```

- [ ] **Step 2: Build the app target**

Run: `swift build --target FlyCommander`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlyCommander/Panes/FileItemCellView.swift
git commit -m "feat(app): add FileItemCellView three-column cell"
```

---

### Task 12: FileCollectionView + PaneView

**Files:**
- Create: `Sources/FlyCommander/Panes/FileCollectionView.swift`
- Create: `Sources/FlyCommander/Panes/PaneView.swift`

**Interfaces:**
- Consumes: `TCCore.FilePane`, `TCCore.Workspace`, `TCCore.CommandRouter`, `TCCore.PaneID`, `KeyDispatcher`, `FileItemCellView`, `PaneColor`.
- Produces:
  - `final class FileCollectionView: NSCollectionView` with `weak var paneView: PaneView?` and `override func mouseDown(with:)` that resolves the clicked item index and calls `paneView?.handleClick(indexPath:control:doubleClick:)`.
  - `final class PaneView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate` with `init(pane:workspace:router:id:)`, `func reload()`, `func setActive(_ active: Bool)`, `func handleClick(indexPath:control:doubleClick:)`, `override func keyDown(with:)`. Exposes `let id: PaneID`.

- [ ] **Step 1: Write `Sources/FlyCommander/Panes/FileCollectionView.swift`**

```swift
import AppKit

final class FileCollectionView: NSCollectionView {
    weak var paneView: PaneView?

    override func mouseDown(with event: NSEvent) {
        guard let pane = paneView else { super.mouseDown(with: event); return }
        let local = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: local) {
            pane.handleClick(indexPath: indexPath,
                              control: event.modifierFlags.contains(.control),
                              doubleClick: event.clickCount >= 2)
        }
    }
}
```

- [ ] **Step 2: Write `Sources/FlyCommander/Panes/PaneView.swift`**

```swift
import AppKit
import TCCore

final class PaneView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let pane: FilePane
    private let workspace: Workspace
    private let router: CommandRouter
    let id: PaneID

    private let flowLayout = NSCollectionViewFlowLayout()
    private let collectionView: FileCollectionView
    private let scrollView: NSScrollView
    private let titleLabel = NSTextField(labelWithString: "")

    private var items: [FileItem] = []
    private var isDarkAppearance = false
    var isActive = false

    init(pane: FilePane, workspace: Workspace, router: CommandRouter, id: PaneID) {
        self.pane = pane
        self.workspace = workspace
        self.router = router
        self.id = id

        flowLayout.scrollDirection = .vertical
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.itemSize = NSSize(width: 500, height: 20)

        let cv = FileCollectionView(frame: .zero, collectionViewLayout: flowLayout)
        cv.isSelectable = false
        cv.backgroundColor = .clear
        cv.isVerticallyResizable = true
        cv.isHorizontallyResizable = false
        cv.hasVerticalScroller = true
        cv.autoresizingMask = [.width]
        cv.translatesAutoresizingMaskIntoConstraints = false
        self.collectionView = cv

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.documentView = cv
        sv.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = sv

        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        collectionView.paneView = self
        collectionView.dataSource = self
        collectionView.delegate = self

        addSubview(titleLabel)
        addSubview(sv)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),
            sv.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidLayout() {
        super.viewDidLayout()
        flowLayout.itemSize = NSSize(width: max(320, scrollView.contentSize.width), height: 20)
        flowLayout.invalidateLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        isDarkAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        reload()
    }

    // MARK: - Data source

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = items[indexPath.item]
        let role = visualRole(for: item,
                              isMarked: pane.selection.isMarked(item.id),
                              isFocus: pane.selection.isFocus(item.id))
        let cell = FileItemCellView()
        _ = cell.view
        (cell as! FileItemCellView).configure(with: item, role: role, dark: isDarkAppearance)
        return cell
    }

    // MARK: - Public

    func reload() {
        items = pane.page?.items ?? []
        collectionView.reloadData()
        updateTitle()
        scrollFocusIntoView()
        updateActiveBorder()
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateActiveBorder()
        reload()
    }

    func handleClick(indexPath: IndexPath, control: Bool, doubleClick: Bool) {
        guard let window = window else { return }
        window.makeFirstResponder(self)
        let idx = indexPath.item
        if workspace.active != id { workspace.activate(id) }
        if control {
            pane.setFocus(to: idx)
            pane.toggleMark(at: idx)
        } else if doubleClick {
            pane.moveFocus(to: idx, mode: .simple)
            router.execute(.enter)
        } else {
            pane.moveFocus(to: idx, mode: .simple)
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self else { super.keyDown(with: event); return }
        let input = KeyInput(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard let result = KeyDispatcher.dispatch(input) else { super.keyDown(with: event); return }
        switch result.command {
        case .rename: promptRename()
        case .makeDirectory: promptMakeDirectory()
        case .delete: router.execute(.delete, moveMode: result.moveMode)
        default: router.execute(result.command, moveMode: result.moveMode)
        }
    }

    // MARK: - Prompts

    private func promptRename() {
        guard let item = pane.focusedItem else { return }
        let alert = NSAlert()
        alert.messageText = "重命名"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            router.rename(to: field.stringValue)
        }
    }

    private func promptMakeDirectory() {
        let alert = NSAlert()
        alert.messageText = "新建目录"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            router.makeDirectory(named: field.stringValue)
        }
    }

    // MARK: - Private

    private func updateTitle() {
        titleLabel.stringValue = pane.path.displayString()
    }

    private func scrollFocusIntoView() {
        let idx = pane.selection.focusIndex
        guard idx >= 0, idx < items.count else { return }
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0))
    }

    private func updateActiveBorder() {
        layer?.borderColor = (isActive ? NSColor.systemBlue : NSColor.separatorColor).cgColor
        layer?.borderWidth = isActive ? 1 : 0.5
    }
}
```

- [ ] **Step 3: Build the app target**

Run: `swift build --target FlyCommander`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/FlyCommander/Panes/FileCollectionView.swift Sources/FlyCommander/Panes/PaneView.swift
git commit -m "feat(app): add FileCollectionView and PaneView"
```

---

### Task 13: CommandBar + StatusBar

**Files:**
- Create: `Sources/FlyCommander/Bars/CommandBar.swift`
- Create: `Sources/FlyCommander/Bars/StatusBar.swift`

**Interfaces:**
- Produces: `final class CommandBar: NSView` with `func setPath(_ path: String, selected: Int)` and `func setStatus(_ s: String)`; `final class StatusBar: NSView` with `func show(diskFree: Int64, selected: Int, totalBytes: Int64)`.

- [ ] **Step 1: Write `Sources/FlyCommander/Bars/CommandBar.swift`**

```swift
import AppKit

final class CommandBar: NSView {
    private let prompt = NSTextField(labelWithString: "> ")
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        prompt.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        for v in [prompt, path, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 2),
            path.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -8),
            path.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.setContentCompressionResistancePriority(.required, for: .horizontal),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPath(_ p: String, selected: Int) {
        path.stringValue = p + (selected > 0 ? "  (\(selected))" : "")
    }

    func setStatus(_ s: String) {
        status.stringValue = s
    }
}
```

- [ ] **Step 2: Write `Sources/FlyCommander/Bars/StatusBar.swift`**

```swift
import AppKit
import Foundation

final class StatusBar: NSView {
    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        left.font = .systemFont(ofSize: 10)
        left.textColor = .secondaryLabelColor
        right.font = .systemFont(ofSize: 10)
        right.textColor = .secondaryLabelColor
        right.alignment = .right

        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)
        addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(diskFree: Int64, selected: Int, totalBytes: Int64) {
        left.stringValue = "磁盘可用 " + ByteCountFormatter().string(fromByteCount: max(0, diskFree))
        right.stringValue = selected > 0
            ? "选中 \(selected) 项 · \(ByteCountFormatter().string(fromByteCount: max(0, totalBytes)))"
            : ""
    }
}
```

- [ ] **Step 3: Build the app target**

Run: `swift build --target FlyCommander`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/FlyCommander/Bars/CommandBar.swift Sources/FlyCommander/Bars/StatusBar.swift
git commit -m "feat(app): add CommandBar and StatusBar"
```

---

### Task 14: Glue — AppDelegate, MainWindowController, MainViewController, main.swift

**Files:**
- Create: `Sources/FlyCommander/App/AppDelegate.swift`
- Create: `Sources/FlyCommander/App/MainWindowController.swift`
- Create: `Sources/FlyCommander/App/MainViewController.swift`
- Modify: `Sources/FlyCommander/main.swift`

**Interfaces:**
- Consumes: `TCCore.Workspace`, `FilePane`, `CommandRouter`, `OperationEngine`, `LocalFileSource`, `TCPath`, `PaneID`, `OperationState`; `PaneView`, `CommandBar`, `StatusBar`.
- Produces: the running application. `MainViewController` owns the core, builds the two-pane layout with command/status bars, wires core callbacks to UI updates, provides the conflict prompt, and performs trash delete via `NSWorkspace.recycle`.

- [ ] **Step 1: Write `Sources/FlyCommander/App/MainViewController.swift`**

```swift
import AppKit
import TCCore

final class MainViewController: NSViewController {
    private let workspace: Workspace
    private let router: CommandRouter
    private var leftPaneView: PaneView!
    private var rightPaneView: PaneView!
    private var commandBar: CommandBar!
    private var statusBar: StatusBar!

    override func loadView() {
        let home = TCPath("~")
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: home)
        let right = FilePane(id: .right, source: source, startPath: home)
        workspace = Workspace(left: left, right: right, active: .left)

        router = CommandRouter(workspace: workspace, engine: OperationEngine())
        router.conflictPrompt = { [weak self] src, dst in self?.promptConflict(src, dst) ?? .overwrite }
        router.onDelete = { [weak self] pane, targets in self?.doTrashDelete(pane: pane, targets: targets) }

        left.onReload = { [weak self] p in self?.refresh(p) }
        right.onReload = { [weak self] p in self?.refresh(p) }
        workspace.onActiveChange = { [weak self] _ in self?.panesDidBecomeActive() }
        workspace.onOperationState = { [weak self] s in self?.operationStateChanged(s) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 680))

        commandBar = CommandBar(frame: .zero)
        statusBar = StatusBar(frame: .zero)
        leftPaneView = PaneView(pane: left, workspace: workspace, router: router, id: .left)
        rightPaneView = PaneView(pane: right, workspace: workspace, router: router, id: .right)
        for v in [leftPaneView, rightPaneView, commandBar, statusBar] { v.translatesAutoresizingMaskIntoConstraints = false }

        root.addSubview(leftPaneView)
        root.addSubview(rightPaneView)
        root.addSubview(commandBar)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            leftPaneView.topAnchor.constraint(equalTo: root.topAnchor),
            leftPaneView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leftPaneView.bottomAnchor.constraint(equalTo: commandBar.topAnchor),
            leftPaneView.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -0.5),

            rightPaneView.topAnchor.constraint(equalTo: root.topAnchor),
            rightPaneView.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 0.5),
            rightPaneView.bottomAnchor.constraint(equalTo: commandBar.topAnchor),
            rightPaneView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            commandBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),
            commandBar.heightAnchor.constraint(equalToConstant: 26),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        self.view = root

        leftPaneView.setActive(true)
        rightPaneView.setActive(false)
        left.load()
        right.load()
        updateBars()
    }

    // MARK: - Core callbacks

    private func refresh(_ pane: FilePane) {
        let pv = pane.id == .left ? leftPaneView : rightPaneView
        pv.reload()
        updateBars()
    }

    private func panesDidBecomeActive() {
        leftPaneView.setActive(workspace.active == .left)
        rightPaneView.setActive(workspace.active == .right)
    }

    private func operationStateChanged(_ s: OperationState) {
        switch s {
        case .running(let label, let progress): commandBar.setStatus("\(label) \(Int(progress * 100))%")
        case .done(let m): commandBar.setStatus(m)
        case .failed(let m): commandBar.setStatus("错误：\(m)")
        case .idle: commandBar.setStatus("")
        }
    }

    private func updateBars() {
        let a = workspace.activePane
        let op = a.selection.operationIDs.count
        commandBar.setPath(a.path.displayString(), selected: op)
        let total = a.operationTargets.reduce(Int64(0)) { $0 + $1.size }
        statusBar.show(diskFree: Self.diskFree(), selected: op, totalBytes: total)
    }

    private static func diskFree() -> Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)
        return (attrs?[.systemFreeSize] as? Int64) ?? 0
    }

    // MARK: - AppKit-provided operations

    private func promptConflict(_ src: TCPath, _ dst: TCPath) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "目标已存在"
        alert.informativeText = "“\(dst.fileName)” 已存在，如何处理？"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "跳过")
        alert.addButton(withTitle: "全部覆盖")
        alert.addButton(withTitle: "全部跳过")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .overwriteAll
        case .alertFourthButtonReturn: return .skipAll
        default: return .cancel
        }
    }

    private func doTrashDelete(pane: FilePane, targets: [FileItem]) {
        if targets.count > 1 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "删除 \(targets.count) 个文件到废纸篓？"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        let urls = targets.map { $0.path.url }
        NSWorkspace.shared.recycle(urls) { [weak self] _, _ in
            DispatchQueue.main.async {
                pane.load()
                self?.workspace.operationState(.done("已删除 \(targets.count) 个文件"))
            }
        }
    }
}
```

- [ ] **Step 2: Write `Sources/FlyCommander/App/MainWindowController.swift`**

```swift
import AppKit

final class MainWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FlyCommander"
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.contentViewController = MainViewController()
        self.init(window: window)
        window.center()
    }
}
```

- [ ] **Step 3: Write `Sources/FlyCommander/App/AppDelegate.swift`**

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = MainWindowController()
        windowController = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 4: Replace `Sources/FlyCommander/main.swift`**

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

- [ ] **Step 5: Build the app target**

Run: `swift build --target FlyCommander`
Expected: builds with no errors.

- [ ] **Step 6: Run the app**

Run: `swift run FlyCommander`
Expected: a two-pane window opens showing your home directory in both panes, with a command bar (`> ~`) and a status bar at the bottom. Click a pane and it becomes first responder.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlyCommander/App Sources/FlyCommander/main.swift
git commit -m "feat(app): wire core to UI (AppDelegate, window, MainViewController glue)"
```

---

### Task 15: End-to-end verification + README

**Files:**
- Create: `README.md`

**Interfaces:**
- No new code. Verifies the P1 acceptance checklist from the spec and documents how to run and the macOS authorization notes.

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests in `TCCoreTests` and `FlyCommanderTests` pass.

- [ ] **Step 2: Build for release**

Run: `swift build -c release`
Expected: builds with no errors.

- [ ] **Step 3: Manual P1 verification** (run `swift run FlyCommander`, then in a scratch directory exercise each item)

Check each (use a scratch folder with several files + a subdirectory):
- [ ] Both panes list files with name / size / date columns; directories are bold.
- [ ] `↑`/`↓` move focus; `→`/`Return` enters a focused directory; `←`/`Backspace` go to parent.
- [ ] `Ctrl+←/→` and `Tab` switch the active pane; a single click activates an inactive pane and moves focus.
- [ ] `Space`/`Option+Q` toggles mark (row turns blue); `Ctrl+↑/↓` additively marks; `Shift+↑/↓` range-marks; status bar selection count updates.
- [ ] `F5` copies to the other pane; on a name conflict the per-file alert appears (覆盖/跳过/全部覆盖/全部跳过/取消); cancel aborts; on completion both panes refresh.
- [ ] `F6` moves to the other pane (source disappears, destination appears).
- [ ] `F7` prompts for a name and creates the directory; `Fn+Delete` (keyCode 117) renames the focused file.
- [ ] `F8` moves selection to Trash (confirm with multiple items); items recoverable from Trash; pane refreshes.
- [ ] Command bar shows the active path + selection count; status bar shows free disk + selection size; operations show progress then a done message.

If any step fails, fix the responsible task's code (not this task) and re-run until the checklist is fully green.

- [ ] **Step 4: Write `README.md`**

```markdown
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
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add README with run instructions and keyboard reference"
```

---

## Self-Review

**Spec coverage:**
- P0 skeleton (Task 1, 14): SPM package, main window, dual-pane layout, key-dispatch skeleton. ✅
- P1 browse (Task 5, 7, 12): directory listing, enter/parent navigation. ✅
- P1 copy/move with per-file conflict prompt + cancel (Task 8, 14). ✅
- P1 delete-to-trash (Task 12 `.delete` path + Task 14 `doTrashDelete`). ✅
- P1 rename + mkdir (Task 8 engine, Task 12 prompts, Task 14 router methods). ✅
- P1 selection model (simple/additive/range/mark/selectAll/clear) (Task 6). ✅
- P1 status bar + command bar (Task 13, 14). ✅
- P1 focus/pane switch TC-classic (Task 7 `Workspace`, Task 12 click, Task 9 `Ctrl+←/→`/Tab). ✅
- P1 TC classic colors (Task 10 `PaneColor`, Task 11 cell, Task 12 `viewDidChangeEffectiveAppearance`). ✅
- Keyboard-first F-key commands (Task 8 router, Task 9 dispatcher). ✅
- Headless, testable core; AppKit never mutates core directly (callbacks only) — enforced by layering constraint. ✅
- Single root SPM package with 3 targets (+ app test target added in Task 9). ✅
- Local-use, no sandbox, run via `swift run`. ✅

**Placeholder scan:** No TBD/TODO; every code step contains full, paste-ready source. Rename/mkdir/delete prompts and the conflict prompt are implemented in concrete code (Task 12/14).

**Type consistency:** `FileItem`/`TCPath`/`FileVisualRole`/`SelectionModel`/`FilePane`/`Workspace`/`OperationEngine`/`CommandRouter`/`CommandID`/`ConflictChoice` signatures are used identically across tasks; `PaneColor`/`FileItemCellView`/`PaneView`/`KeyDispatcher` reference the core types by their exact names. `onDelete` is `(FilePane, [FileItem]) -> Void` in both `CommandRouter` (Task 8) and the AppKit closure (Task 14). `OperationState` cases match between `Workspace` (Task 7) and `MainViewController.operationStateChanged` (Task 14).

**Known P1 simplifications (documented, not blockers):** directory pages load fully (no virtualized pagination — `DirectoryPage.hasMore` reserved); conflict prompt and file ops run on the main thread (progress is best-effort for very large directories); trash delete is async-optimistic with a main-thread reload on completion. These are acceptable for a local P1 milestone and are flagged in the spec's "假设与待决" section.
