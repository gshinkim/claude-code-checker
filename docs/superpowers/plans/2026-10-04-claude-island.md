# Claude Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A notch-hugging macOS island that lists every Claude Code session, shakes when one stops or needs input, and jumps to it on click.

**Architecture:** One Swift executable, `claude-island`. Run with no arguments it is the island app; run as `claude-island hook` it is called by Claude Code hooks and writes one JSON file per session to `~/.claude/island/sessions/`. The app watches that folder. No server, no dependencies.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, AppKit (`NSPanel`), SwiftUI, `NSAppleScript`.

**Spec:** `docs/superpowers/specs/2026-10-04-claude-island-design.md`

## Global Constraints

- macOS 14 or later. Only the command-line tools are installed: no Xcode, and neither `XCTest` nor `Testing` is available (verified: `import Testing` fails). All automated checks run through `claude-island selfcheck`.
- No third-party dependencies.
- `claude-island hook` always exits 0 and prints nothing, whatever its input.
- `~/.claude/settings.json` is never written without first copying it to `settings.json.island-backup`. Existing keys and hooks are preserved.
- No sound, no settings UI, no Dock icon.
- Build with `swift build`; binary at `.build/debug/claude-island`.
- Hooks are read when a Claude Code session starts. After installing, only new sessions report to the island.

## Review Focus

1. A `session_id` containing path characters (`../../x`) must be ignored; nothing is written outside the sessions folder. Pinned in Task 1 (`isSafeId`) and Task 2 (shell check).
2. Empty or malformed stdin to `hook` must exit 0 silently and write nothing. Pinned in Task 2.
3. The first event seen for a session is not `SessionStart` (island installed mid-session): the session must still appear. Pinned in Task 1.
4. `settings.json` that already has other tools' hooks on the same events, or has no `hooks` key: both survive install and uninstall unchanged. Pinned in Task 3.
5. A garbage or half-written file in the sessions folder must be skipped without hiding the valid sessions. Pinned in Task 4.

## File Structure

```
Package.swift
.gitignore
scripts/bundle.sh                      build + wrap into ~/Applications/ClaudeIsland.app
Sources/ClaudeIsland/
  main.swift                           subcommand dispatch
  Session.swift                        Session, SessionState, Host, Paths, JSON coders
  StateMapping.swift                   HookEvent, pure event -> state rules
  HostDetector.swift                   find Claude pid, tty, owning app from the process tree
  HookCommand.swift                    stdin -> session file
  Installer.swift                      settings.json merge, LaunchAgent
  SessionStore.swift                   watch folder, publish sessions, prune, alert tick
  Jumper.swift                         focus a session's window
  PetView.swift                        the pet
  IslandView.swift                     pill, expanded list, shake
  AppDelegate.swift                    the panel over the notch
  SelfCheck.swift                      all automated checks
```

---

### Task 1: Package, session model, state rules

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/ClaudeIsland/main.swift`, `Sources/ClaudeIsland/Session.swift`, `Sources/ClaudeIsland/StateMapping.swift`, `Sources/ClaudeIsland/SelfCheck.swift`

**Interfaces:**
- Produces:
  - `enum SessionState: String, Codable { case idle, working, done, needsYou }`
  - `struct Session: Codable, Equatable, Identifiable` with `id, cwd: String; state: SessionState; attention: Bool; updatedAt: Date; pid: Int32; tty, hostBundleId, hostName: String?`; `Session.encoder`, `Session.decoder`
  - `struct Host: Equatable { var pid: Int32; var tty: String?; var bundleId: String?; var name: String? }`
  - `enum Paths { static let sessionsDir, settings, launchAgent: URL; static func file(_ id: String) -> URL }`
  - `struct HookEvent: Decodable { var sessionId, hookEventName: String; var cwd, notificationType: String? }`
  - `StateMapping.isSafeId(_:) -> Bool`
  - `StateMapping.apply(_ e: HookEvent, to previous: Session?, host: Host, now: Date) -> Session?` (nil means remove)
  - `SelfCheck.check(_ ok: Bool, _ name: String)`, `SelfCheck.run() -> Never`

- [ ] **Step 1: Scaffold**

```bash
cd /Users/you/Desktop/Dynamic_Island && git init && mkdir -p Sources/ClaudeIsland scripts
printf '.build/\n' > .gitignore
```

`Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "claude-island",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "claude-island",
            path: "Sources/ClaudeIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
```

`Sources/ClaudeIsland/Session.swift`:

```swift
import Foundation

enum SessionState: String, Codable { case idle, working, done, needsYou }

struct Session: Codable, Equatable, Identifiable {
    var id: String
    var cwd: String
    var state: SessionState
    var attention: Bool
    var updatedAt: Date
    var pid: Int32
    var tty: String?
    var hostBundleId: String?
    var hostName: String?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}

struct Host: Equatable {
    var pid: Int32
    var tty: String?
    var bundleId: String?
    var name: String?
}

enum Paths {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let sessionsDir = home.appendingPathComponent(".claude/island/sessions")
    static let settings = home.appendingPathComponent(".claude/settings.json")
    static let launchAgent = home.appendingPathComponent("Library/LaunchAgents/com.claudeisland.app.plist")
    static func file(_ id: String) -> URL { sessionsDir.appendingPathComponent("\(id).json") }
}
```

- [ ] **Step 2: Write the failing checks**

`Sources/ClaudeIsland/SelfCheck.swift`:

```swift
import Foundation

enum SelfCheck {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "ok   " : "FAIL ", name)
        if !ok { failures += 1 }
    }

    static func run() -> Never {
        checkStateMapping()
        print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func checkStateMapping() {
        let host = Host(pid: 42, tty: "/dev/ttys001", bundleId: "com.apple.Terminal", name: "Terminal")
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        func ev(_ name: String, _ type: String? = nil) -> HookEvent {
            HookEvent(sessionId: "s1", hookEventName: name, cwd: "/tmp/demo", notificationType: type)
        }
        func step(_ name: String, _ type: String? = nil, from s: Session?, at: Date = t1) -> Session? {
            StateMapping.apply(ev(name, type), to: s, host: host, now: at)
        }

        let started = step("SessionStart", from: nil, at: t0)
        check(started?.state == .idle && started?.attention == false, "SessionStart creates an idle session")
        check(started?.pid == 42 && started?.cwd == "/tmp/demo", "new session records host and cwd")

        let working = step("UserPromptSubmit", from: started)
        check(working?.state == .working && working?.updatedAt == t1, "UserPromptSubmit -> working")

        let done = step("Stop", from: working)
        check(done?.state == .done && done?.attention == true, "Stop -> done with attention")

        let needs = step("Notification", "permission_prompt", from: working)
        check(needs?.state == .needsYou && needs?.attention == true, "Notification -> needsYou with attention")

        check(step("Notification", "idle_prompt", from: done) == done, "idle reminder changes nothing")

        let granted = step("PostToolUse", from: needs)
        check(granted?.state == .working && granted?.attention == false, "PostToolUse leaves needsYou")

        let again = StateMapping.apply(ev("PostToolUse"), to: working, host: host, now: Date(timeIntervalSince1970: 3000))
        check(again == working, "repeated PostToolUse does not touch updatedAt")

        check(step("SessionStart", from: working) == working, "SessionStart on a known session changes nothing")
        check(step("SessionEnd", from: working) == nil, "SessionEnd removes")

        let late = step("Stop", from: nil)
        check(late?.state == .done && late?.attention == true, "first event may be Stop (installed mid-session)")

        check(StateMapping.isSafeId("abc-123_X"), "normal id is safe")
        check(!StateMapping.isSafeId("../../evil"), "path characters are rejected")
        check(!StateMapping.isSafeId(""), "empty id is rejected")

        let json = #"{"session_id":"a","hook_event_name":"Notification","cwd":"/x","notification_type":"idle_prompt","extra":1}"#
        let decoded = try? JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        check(decoded?.sessionId == "a" && decoded?.notificationType == "idle_prompt", "HookEvent decodes Claude Code JSON")
    }
}
```

`Sources/ClaudeIsland/main.swift`:

```swift
import Foundation

switch CommandLine.arguments.dropFirst().first {
case "selfcheck":
    SelfCheck.run()
default:
    FileHandle.standardError.write(Data("usage: claude-island [hook|install|uninstall|selfcheck]\n".utf8))
    exit(2)
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: build error, `cannot find 'StateMapping' in scope` / `cannot find 'HookEvent' in scope`.

- [ ] **Step 4: Implement**

`Sources/ClaudeIsland/StateMapping.swift`:

```swift
import Foundation

struct HookEvent: Decodable {
    var sessionId: String
    var hookEventName: String
    var cwd: String?
    var notificationType: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case hookEventName = "hook_event_name"
        case cwd
        case notificationType = "notification_type"
    }
}

enum StateMapping {
    /// The id becomes a file name, so only allow characters that cannot leave the folder.
    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    /// Returns the session after the event, or nil when it should be removed.
    static func apply(_ e: HookEvent, to previous: Session?, host: Host, now: Date) -> Session? {
        if e.hookEventName == "SessionEnd" { return nil }
        var s = previous ?? Session(
            id: e.sessionId, cwd: e.cwd ?? "", state: .idle, attention: false, updatedAt: now,
            pid: host.pid, tty: host.tty, hostBundleId: host.bundleId, hostName: host.name)

        let target: (SessionState, Bool)?
        switch e.hookEventName {
        case "UserPromptSubmit", "PostToolUse": target = (.working, false)
        case "Stop": target = (.done, true)
        case "Notification": target = e.notificationType == "idle_prompt" ? nil : (.needsYou, true)
        default: target = nil
        }
        if let (state, attention) = target, state != s.state {
            s.state = state
            s.attention = attention
            s.updatedAt = now
        }
        return s
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/claude-island selfcheck`
Expected: every line starts with `ok`, last line `all checks passed`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: session model and state rules"
```

---

### Task 2: Hook command and host detection

**Files:**
- Create: `Sources/ClaudeIsland/HostDetector.swift`, `Sources/ClaudeIsland/HookCommand.swift`
- Modify: `Sources/ClaudeIsland/main.swift`, `Sources/ClaudeIsland/SelfCheck.swift`

**Interfaces:**
- Consumes: `Session`, `Host`, `Paths`, `HookEvent`, `StateMapping.apply`, `StateMapping.isSafeId`, `SelfCheck.check`
- Produces:
  - `struct Proc { var ppid: Int32; var tty: String; var comm: String }`
  - `HostDetector.resolve(start: Int32, table: [Int32: Proc]) -> (pid: Int32, tty: String?, appPath: String?)`
  - `HostDetector.detect() -> Host`
  - `HookCommand.run()`

Background: Claude Code runs a hook as a child process, sometimes through `sh -c`. So the hook's parent is either Claude Code or a shell whose parent is Claude Code. The owning app is the first ancestor whose executable path is inside a `.app` bundle. `ps -o comm=` on macOS prints the full executable path; `tty` prints `ttys004` or `??`.

- [ ] **Step 1: Write the failing checks**

Add to `SelfCheck.swift`, inside `enum SelfCheck`:

```swift
    static func checkHostDetector() {
        let terminal: [Int32: Proc] = [
            500: Proc(ppid: 400, tty: "ttys004", comm: "/bin/sh"),
            400: Proc(ppid: 300, tty: "ttys004", comm: "/Users/you/.local/bin/claude"),
            300: Proc(ppid: 200, tty: "ttys004", comm: "-zsh"),
            200: Proc(ppid: 100, tty: "ttys004", comm: "login"),
            100: Proc(ppid: 1, tty: "??", comm: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        let a = HostDetector.resolve(start: 500, table: terminal)
        check(a.pid == 400, "skips the sh wrapper to find Claude Code")
        check(a.tty == "/dev/ttys004", "reads the tty")
        check(a.appPath == "/System/Applications/Utilities/Terminal.app", "finds the owning app")

        let b = HostDetector.resolve(start: 400, table: terminal)
        check(b.pid == 400, "works when the hook's parent is Claude Code itself")

        let desktop: [Int32: Proc] = [
            40: Proc(ppid: 30, tty: "??", comm: "/Users/you/Library/Application Support/Claude/claude-code/claude"),
            30: Proc(ppid: 20, tty: "??", comm: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            20: Proc(ppid: 1, tty: "??", comm: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
        let c = HostDetector.resolve(start: 40, table: desktop)
        check(c.tty == nil, "no tty in the desktop app")
        check(c.appPath == "/Applications/Claude.app", "nested helper resolves to the outer app")

        let d = HostDetector.resolve(start: 9, table: [9: Proc(ppid: 1, tty: "??", comm: "tmux")])
        check(d.appPath == nil && d.pid == 9, "no owning app is not an error")
    }
```

In `run()`, add `checkHostDetector()` on the line after `checkStateMapping()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `cannot find 'Proc' in scope` / `cannot find 'HostDetector' in scope`.

- [ ] **Step 3: Implement**

`Sources/ClaudeIsland/HostDetector.swift`:

```swift
import Foundation

struct Proc {
    var ppid: Int32
    var tty: String
    var comm: String
}

enum HostDetector {
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish"]

    private static func baseName(_ comm: String) -> String {
        let name = comm.split(separator: "/").last.map(String.init) ?? comm
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    static func resolve(start: Int32, table: [Int32: Proc]) -> (pid: Int32, tty: String?, appPath: String?) {
        var pid = start
        while let p = table[pid], shells.contains(baseName(p.comm)), p.ppid > 1 { pid = p.ppid }

        let rawTTY = table[pid]?.tty ?? "??"
        let tty = rawTTY.hasPrefix("tty") ? "/dev/" + rawTTY : nil

        var cur = pid, hops = 0
        while let p = table[cur], hops < 32 {
            if let r = p.comm.range(of: ".app/") {
                return (pid, tty, String(p.comm[..<r.lowerBound]) + ".app")
            }
            cur = p.ppid
            hops += 1
        }
        return (pid, tty, nil)
    }

    static func processTable() -> [Int32: Proc] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,ppid=,tty=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [:] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        var table: [Int32: Proc] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            table[pid] = Proc(ppid: ppid, tty: String(f[2]), comm: f[3].trimmingCharacters(in: .whitespaces))
        }
        return table
    }

    static func detect() -> Host {
        let r = resolve(start: getppid(), table: processTable())
        let name = r.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? ProcessInfo.processInfo.environment["TERM_PROGRAM"]
        return Host(pid: r.pid, tty: r.tty,
                    bundleId: r.appPath.flatMap { Bundle(path: $0)?.bundleIdentifier },
                    name: name)
    }
}
```

`Sources/ClaudeIsland/HookCommand.swift`:

```swift
import Foundation

enum HookCommand {
    /// Never throws, never prints: a hook must not disturb the session that called it.
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: input),
              StateMapping.isSafeId(event.sessionId) else { return }

        let url = Paths.file(event.sessionId)
        let previous = (try? Data(contentsOf: url)).flatMap { try? Session.decoder.decode(Session.self, from: $0) }
        // Host detection spawns ps, so do it once per session, not on every tool call.
        let host = previous.map { Host(pid: $0.pid, tty: $0.tty, bundleId: $0.hostBundleId, name: $0.hostName) }
            ?? HostDetector.detect()

        guard let next = StateMapping.apply(event, to: previous, host: host, now: Date()) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if next == previous { return }
        try? FileManager.default.createDirectory(at: Paths.sessionsDir, withIntermediateDirectories: true)
        try? Session.encoder.encode(next).write(to: url, options: .atomic)
    }
}
```

In `main.swift`, add above `case "selfcheck":`:

```swift
case "hook":
    HookCommand.run()
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/claude-island selfcheck`
Expected: `all checks passed`.

- [ ] **Step 5: Check the real command, including the Review Focus inputs**

```bash
B=.build/debug/claude-island; D=~/.claude/island
echo '{"session_id":"plan-test","hook_event_name":"Stop","cwd":"/tmp/demo"}' | $B hook; echo "exit=$?"; cat $D/sessions/plan-test.json; echo
echo '{"session_id":"plan-test","hook_event_name":"SessionEnd"}' | $B hook; ls $D/sessions
echo 'not json' | $B hook; echo "exit=$?"
printf '' | $B hook; echo "exit=$?"
echo '{"session_id":"../../evil","hook_event_name":"Stop"}' | $B hook; echo "exit=$?"; ls ~/.claude | grep -c evil
time (echo '{"session_id":"plan-test","hook_event_name":"PostToolUse"}' | $B hook); rm -f $D/sessions/plan-test.json
```

Expected, in order: `exit=0` and a JSON object with `"state":"done"`, `"attention":true`, and (when run from Terminal) `"tty":"/dev/ttys…"` and `"hostName":"Terminal"`; then an empty listing; then `exit=0` three times with no other output; `0` for the evil count; `real` under 0.15 s.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: hook command with host detection"
```

---

### Task 3: Installer

**Files:**
- Create: `Sources/ClaudeIsland/Installer.swift`, `scripts/bundle.sh`
- Modify: `Sources/ClaudeIsland/main.swift`, `Sources/ClaudeIsland/SelfCheck.swift`

**Interfaces:**
- Consumes: `Paths.settings`, `Paths.launchAgent`, `SelfCheck.check`
- Produces:
  - `Installer.events: [String]`
  - `Installer.merge(_ settings: [String: Any], command: String) -> [String: Any]`
  - `Installer.strip(_ settings: [String: Any]) -> [String: Any]`
  - `Installer.install() -> Never`, `Installer.uninstall() -> Never`
  - `scripts/bundle.sh` producing `~/Applications/ClaudeIsland.app`

Background: hooks in `settings.json` look like `{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "…"}]}]}}`. Each event holds a list of groups; a group may have a `matcher` and holds a list of hook commands. This machine already has `PreToolUse` groups for another tool; they must survive.

- [ ] **Step 1: Write the failing checks**

Add to `SelfCheck.swift`, inside `enum SelfCheck`:

```swift
    static func checkInstaller() {
        func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
        let cmd = "\"/Users/you/Applications/ClaudeIsland.app/Contents/MacOS/claude-island\" hook"
        let other: [String: Any] = ["type": "command", "command": "/usr/local/bin/other-tool stop"]
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [["matcher": "Bash|Grep", "hooks": [["type": "command", "command": "graphify hook-guard search", "timeout": 10]]]],
                "Stop": [["hooks": [other]]],
            ],
        ]

        let merged = Installer.merge(existing, command: cmd)
        let hooks = merged["hooks"] as? [String: Any] ?? [:]
        check(merged["model"] as? String == "opus", "merge keeps unrelated keys")
        check(NSArray(array: hooks["PreToolUse"] as? [Any] ?? []).isEqual(to: (existing["hooks"] as! [String: Any])["PreToolUse"] as! [Any]),
              "merge keeps other events untouched")
        check(Installer.events.allSatisfy { (hooks[$0] as? [[String: Any]])?.isEmpty == false }, "merge adds every event")
        check((hooks["Stop"] as? [[String: Any]])?.count == 2, "merge keeps another tool's hook on the same event")
        check(same(Installer.merge(merged, command: cmd), merged), "merge is idempotent")
        check(same(Installer.strip(merged), existing), "strip removes only our entries")

        let bare: [String: Any] = ["theme": "dark"]
        check(((Installer.merge(bare, command: cmd)["hooks"] as? [String: Any])?.count ?? 0) == Installer.events.count,
              "merge works with no hooks key")
        check(same(Installer.strip(Installer.merge(bare, command: cmd)), bare), "strip restores a file that had no hooks key")
    }
```

In `run()`, add `checkInstaller()` after `checkHostDetector()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `cannot find 'Installer' in scope`.

- [ ] **Step 3: Implement**

`Sources/ClaudeIsland/Installer.swift`:

```swift
import Foundation

enum Installer {
    static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"]

    private static func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("claude-island") && command.hasSuffix(" hook")
    }

    static func strip(_ settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return out }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let inner = group["hooks"] as? [[String: Any]] else { return group }
                let rest = inner.filter { !isOurs($0["command"] as? String) }
                if rest.count == inner.count { return group }
                if rest.isEmpty { return nil }
                var g = group
                g["hooks"] = rest
                return g
            }
            if kept.count == groups.count && kept.isEmpty { continue }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        return out
    }

    static func merge(_ settings: [String: Any], command: String) -> [String: Any] {
        var out = strip(settings)
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            hooks[event] = groups
        }
        out["hooks"] = hooks
        return out
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.settings),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("Could not read \(Paths.settings.path) as JSON. Nothing was changed.")
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any]) {
        let fm = FileManager.default
        let backup = Paths.settings.appendingPathExtension("island-backup")
        do {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: Paths.settings, to: backup)
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Paths.settings, options: .atomic)
        } catch {
            fail("Could not update settings: \(error.localizedDescription)")
        }
        print("Backup: \(backup.path)")
    }

    static func install() -> Never {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path else { fail("Cannot find own path.") }
        writeSettings(merge(readSettings(), command: "\"\(exe)\" hook"))

        let plist: [String: Any] = ["Label": "com.claudeisland.app", "ProgramArguments": [exe], "RunAtLoad": true]
        do {
            try FileManager.default.createDirectory(at: Paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: Paths.launchAgent, options: .atomic)
        } catch {
            fail("Hooks installed, but launch at login failed: \(error.localizedDescription)")
        }
        print("Installed. New Claude Code sessions will report to the island; it starts at login.")
        exit(0)
    }

    static func uninstall() -> Never {
        writeSettings(strip(readSettings()))
        try? FileManager.default.removeItem(at: Paths.launchAgent)
        print("Uninstalled.")
        exit(0)
    }
}
```

Note: the settings file is rewritten with sorted keys, so its key order and spacing change once. Content is preserved.

In `main.swift`, add above `case "selfcheck":`:

```swift
case "install":
    Installer.install()
case "uninstall":
    Installer.uninstall()
```

`scripts/bundle.sh`:

```bash
#!/bin/bash
# Build a release binary and wrap it in ~/Applications/ClaudeIsland.app
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$HOME/Applications/ClaudeIsland.app"
pkill -x claude-island || true
mkdir -p "$APP/Contents/MacOS"
cp .build/release/claude-island "$APP/Contents/MacOS/claude-island"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.claudeisland.app</string>
  <key>CFBundleExecutable</key><string>claude-island</string>
  <key>CFBundleName</key><string>Claude Island</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Claude Island selects the terminal tab of the session you click.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
```

```bash
chmod +x scripts/bundle.sh
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/claude-island selfcheck`
Expected: `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: installer and app bundle script"
```

- [ ] **Step 6: Install for real, with the user's go-ahead**

This edits the global `~/.claude/settings.json`. Ask the user before running.

```bash
scripts/bundle.sh && ~/Applications/ClaudeIsland.app/Contents/MacOS/claude-island install
python3 -c "import json,os; h=json.load(open(os.path.expanduser('~/.claude/settings.json')))['hooks']; print(sorted(h)); print(len(h['PreToolUse']))"
```

Expected: a `Backup:` line, `Installed.`, the event list including the six island events plus `PreToolUse`, and `2` (the two existing `PreToolUse` groups are intact).

- [ ] **Step 7: Resolve spec risk 1: do hooks fire in the desktop app?**

Start a new `claude` session in Terminal and a new session in the Claude desktop app's Code tab; send each a short prompt. Then:

```bash
grep -h -o '"hostName":"[^"]*"' ~/.claude/island/sessions/*.json | sort | uniq -c
```

Expected: one line for `Terminal` and one for `Claude`. If the desktop session is missing, stop and tell the user: desktop sessions cannot be tracked through `settings.json` hooks and the design needs a decision before continuing.

---

### Task 4: Session store

**Files:**
- Create: `Sources/ClaudeIsland/SessionStore.swift`
- Modify: `Sources/ClaudeIsland/SelfCheck.swift`

**Interfaces:**
- Consumes: `Session`, `Paths.sessionsDir`, `SelfCheck.check`
- Produces:
  - `final class SessionStore: ObservableObject` with `@Published private(set) var sessions: [Session]`, `@Published private(set) var alertTick: Int`
  - `init(dir: URL = Paths.sessionsDir)`
  - `func clearAttention(_ s: Session)`
  - `static func load(from dir: URL) -> [Session]`
  - `static func shouldAlert(old: [Session], new: [Session]) -> Bool`
  - `static func isAlive(_ pid: Int32) -> Bool`

- [ ] **Step 1: Write the failing checks**

Add to `SelfCheck.swift`, inside `enum SelfCheck`:

```swift
    static func checkSessionStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("island-check-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func make(_ id: String, _ state: SessionState, attention: Bool, at t: TimeInterval) -> Session {
            Session(id: id, cwd: "/tmp/\(id)", state: state, attention: attention,
                    updatedAt: Date(timeIntervalSince1970: t), pid: getpid(), tty: nil, hostBundleId: nil, hostName: nil)
        }
        let old = make("old", .working, attention: false, at: 100)
        let new = make("new", .working, attention: false, at: 300)
        let flagged = make("flagged", .done, attention: true, at: 200)
        for s in [old, new, flagged] {
            try? Session.encoder.encode(s).write(to: dir.appendingPathComponent("\(s.id).json"))
        }
        try? Data("{ half written".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try? Data("ignore me".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let loaded = SessionStore.load(from: dir)
        check(loaded.map(\.id) == ["flagged", "new", "old"], "load skips bad files, sorts attention first then newest")

        check(SessionStore.shouldAlert(old: [old], new: [old, flagged]), "new attention session alerts")
        check(!SessionStore.shouldAlert(old: [flagged], new: [flagged, new]), "unchanged attention session does not alert again")
        var cleared = flagged; cleared.attention = false
        check(!SessionStore.shouldAlert(old: [flagged], new: [cleared]), "clearing attention does not alert")
        var again = flagged; again.state = .needsYou; again.updatedAt = Date(timeIntervalSince1970: 400)
        check(SessionStore.shouldAlert(old: [flagged], new: [again]), "a second stop on a flagged session alerts")

        check(SessionStore.isAlive(getpid()), "own pid is alive")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run(); p.waitUntilExit()
        check(!SessionStore.isAlive(p.processIdentifier), "exited pid is not alive")
    }
```

In `run()`, add `checkSessionStore()` after `checkInstaller()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `cannot find 'SessionStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/ClaudeIsland/SessionStore.swift`:

```swift
import Foundation
import Combine

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    /// Bumped whenever a session newly needs attention; the view shakes on each change.
    @Published private(set) var alertTick = 0

    private let dir: URL
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    init(dir: URL = Paths.sessionsDir) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessions = Self.load(from: dir)

        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.reload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.prune()
            self?.reload()
        }
    }

    static func load(from dir: URL) -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Session.decoder.decode(Session.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.attention ? 1 : 0, $0.updatedAt) > ($1.attention ? 1 : 0, $1.updatedAt) }
    }

    static func shouldAlert(old: [Session], new: [Session]) -> Bool {
        new.contains { n in
            n.attention && !old.contains {
                $0.id == n.id && $0.attention && $0.state == n.state && $0.updatedAt == n.updatedAt
            }
        }
    }

    static func isAlive(_ pid: Int32) -> Bool {
        pid <= 1 || kill(pid, 0) == 0 || errno == EPERM
    }

    func reload() {
        let new = Self.load(from: dir)
        guard new != sessions else { return }
        if Self.shouldAlert(old: sessions, new: new) { alertTick += 1 }
        sessions = new
    }

    private func prune() {
        for s in sessions where !Self.isAlive(s.pid) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id).json"))
        }
    }

    func clearAttention(_ s: Session) {
        var c = s
        c.attention = false
        try? Session.encoder.encode(c).write(to: dir.appendingPathComponent("\(s.id).json"), options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/claude-island selfcheck`
Expected: `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: session store"
```

---

### Task 5: Jumper

**Files:**
- Create: `Sources/ClaudeIsland/Jumper.swift`
- Modify: `Sources/ClaudeIsland/SelfCheck.swift`

**Interfaces:**
- Consumes: `Session`, `SelfCheck.check`
- Produces:
  - `Jumper.isSafeTTY(_:) -> Bool`
  - `Jumper.script(bundleId: String, tty: String) -> String?`
  - `Jumper.jump(to s: Session)`

The tty is interpolated into AppleScript source, so it is validated first.

- [ ] **Step 1: Write the failing checks**

Add to `SelfCheck.swift`, inside `enum SelfCheck`:

```swift
    static func checkJumper() {
        check(Jumper.isSafeTTY("/dev/ttys004"), "normal tty is safe")
        check(!Jumper.isSafeTTY("/dev/ttys004\"\ndo shell script \"x"), "tty with script text is rejected")
        check(Jumper.script(bundleId: "com.apple.Terminal", tty: "/dev/ttys004")?.contains("\"/dev/ttys004\"") == true,
              "Terminal script targets the tty")
        check(Jumper.script(bundleId: "com.googlecode.iterm2", tty: "/dev/ttys004")?.contains("iTerm2") == true,
              "iTerm2 has a script")
        check(Jumper.script(bundleId: "com.mitchellh.ghostty", tty: "/dev/ttys004") == nil, "other apps have no script")
        check(Jumper.script(bundleId: "com.apple.Terminal", tty: "bad") == nil, "unsafe tty produces no script")
    }
```

In `run()`, add `checkJumper()` after `checkSessionStore()`.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build 2>&1 | tail -5`
Expected: `cannot find 'Jumper' in scope`.

- [ ] **Step 3: Implement**

`Sources/ClaudeIsland/Jumper.swift`:

```swift
import AppKit

enum Jumper {
    /// Opening the folder with these focuses the window that already has it open.
    private static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // last one is Cursor
    ]

    static func isSafeTTY(_ tty: String) -> Bool {
        tty.range(of: #"^/dev/ttys[0-9]{1,5}$"#, options: .regularExpression) != nil
    }

    static func script(bundleId: String, tty: String) -> String? {
        guard isSafeTTY(tty) else { return nil }
        switch bundleId {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    static func jump(to s: Session) {
        guard let bundleId = s.hostBundleId,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }

        if let tty = s.tty, let source = script(bundleId: bundleId, tty: tty) {
            var error: NSDictionary?
            if NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue == true { return }
        }
        let config = NSWorkspace.OpenConfiguration()
        if editors.contains(bundleId) {
            NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build 2>&1 | tail -3 && .build/debug/claude-island selfcheck`
Expected: `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: jump to a session's window"
```

---

### Task 6: The island window, views and pet

**Files:**
- Create: `Sources/ClaudeIsland/PetView.swift`, `Sources/ClaudeIsland/IslandView.swift`, `Sources/ClaudeIsland/AppDelegate.swift`
- Modify: `Sources/ClaudeIsland/main.swift`

**Interfaces:**
- Consumes: `SessionStore` (`sessions`, `alertTick`, `clearAttention`), `Session`, `Jumper.jump(to:)`
- Produces: `PetView(size: CGFloat, shakes: CGFloat)`, `IslandView(store: SessionStore, notch: CGSize)`, `AppDelegate`

How the window works: the panel is a fixed 440 x 340 transparent window pinned to the top center of the screen. The black pill is drawn inside it and animates its own size, so the window never resizes. macOS passes clicks through the fully transparent parts of a non-opaque borderless window, so the menu bar and windows underneath stay usable.

No automated checks: this task is views. It is verified by running it (Step 3).

- [ ] **Step 1: Write the views**

`Sources/ClaudeIsland/PetView.swift`:

```swift
import SwiftUI

/// Rotates left and right three times as `animatableData` goes from n to n+1.
struct HeadShake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let angle = 0.35 * sin(animatableData * .pi * 6)
        let t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .rotated(by: angle)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(t)
    }
}

/// The Claude starburst with two eyes.
struct PetView: View {
    let size: CGFloat
    var shakes: CGFloat
    @State private var bob = false
    private let orange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                Capsule().fill(orange)
                    .frame(width: size * 0.2, height: size)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            Circle().fill(orange).frame(width: size * 0.6, height: size * 0.6)
            HStack(spacing: size * 0.12) { eye; eye }
        }
        .frame(width: size, height: size)
        .modifier(HeadShake(animatableData: shakes))
        .offset(y: bob ? -1 : 1)
        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: bob)
        .onAppear { bob = true }
    }

    private var eye: some View {
        Circle().fill(.black).frame(width: size * 0.13, height: size * 0.13)
    }
}
```

`Sources/ClaudeIsland/IslandView.swift`:

```swift
import SwiftUI

/// Slides left and right three times as `animatableData` goes from n to n+1.
struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 6), y: 0))
    }
}

struct SessionRow: View {
    let session: Session

    private var label: String {
        switch session.state {
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .needsYou: "Needs you"
        }
    }
    private var color: Color {
        switch session.state {
        case .idle: .gray
        case .working: .blue
        case .done: .green
        case .needsYou: .orange
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: session.cwd).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(session.hostName ?? "Unknown") · \(label)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.updatedAt, style: .relative)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(session.attention ? Color.orange.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    let notch: CGSize
    @State private var expanded = false
    @State private var shakes: CGFloat = 0

    private let wing: CGFloat = 34
    private var attentionCount: Int { store.sessions.filter(\.attention).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PetView(size: 18, shakes: shakes).frame(width: wing).opacity(expanded ? 0 : 1)
                Spacer(minLength: notch.width)
                Text(attentionCount > 0 ? "\(attentionCount)" : "")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
                    .frame(width: wing)
            }
            .frame(height: notch.height)
            if expanded { list }
        }
        .frame(width: expanded ? max(360, notch.width + wing * 2) : notch.width + wing * 2)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.spring(duration: 0.3)) { expanded = hovering } }
        .contextMenu { Button("Quit Claude Island") { NSApp.terminate(nil) } }
        .modifier(Shake(animatableData: shakes))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(store.$alertTick.dropFirst()) { _ in
            withAnimation(.linear(duration: 0.5)) { shakes += 1 }
        }
    }

    private var list: some View {
        HStack(alignment: .top, spacing: 12) {
            PetView(size: 44, shakes: shakes)
            VStack(alignment: .leading, spacing: 6) {
                if store.sessions.isEmpty {
                    Text("No Claude Code sessions").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                // ponytail: shows the first 6 sessions; add a ScrollView if more are ever run at once
                ForEach(store.sessions.prefix(6)) { s in
                    SessionRow(session: s).onTapGesture {
                        store.clearAttention(s)
                        Jumper.jump(to: s)
                    }
                }
            }
        }
        .padding(12)
    }
}
```

`Sources/ClaudeIsland/AppDelegate.swift`:

```swift
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var panel: NSPanel!
    private let size = CGSize(width: 440, height: 340)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        place()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.place() }
        panel.orderFrontRegardless()
    }

    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let view = IslandView(store: store, notch: Self.notchSize(of: screen)).environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setFrame(CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// The notch is the gap between the two usable strips either side of it. No notch: a menu-bar-height pill.
    static func notchSize(of screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 180, height: 28)
        }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }
}
```

Replace `main.swift` with:

```swift
import AppKit

switch CommandLine.arguments.dropFirst().first {
case nil:
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
case "hook":
    HookCommand.run()
case "install":
    Installer.install()
case "uninstall":
    Installer.uninstall()
case "selfcheck":
    SelfCheck.run()
default:
    FileHandle.standardError.write(Data("usage: claude-island [hook|install|uninstall|selfcheck]\n".utf8))
    exit(2)
}
```

- [ ] **Step 2: Build and re-run the checks**

Run: `swift build 2>&1 | tail -3 && .build/debug/claude-island selfcheck`
Expected: builds; `all checks passed`.

- [ ] **Step 3: Run it and verify by eye**

```bash
scripts/bundle.sh && open ~/Applications/ClaudeIsland.app
```

Take a screenshot (`screencapture -x <scratchpad>/island.png`) and read it at each point. Verify, in order:

1. A black pill hugs the notch with the pet in its left wing. No Dock icon.
2. Hovering expands it; the list shows the live sessions from Task 3 Step 7. Moving away collapses it.
3. Fake an alert and watch the shake, the pet's head shake, the orange row, and the count:

```bash
echo '{"session_id":"shake-test","hook_event_name":"Stop","cwd":"/tmp/shake-demo"}' | ~/Applications/ClaudeIsland.app/Contents/MacOS/claude-island hook
```

4. Clicking that row clears its highlight and the count.
5. Click a menu bar item just beside the pill, and a window lying under the transparent part of the panel: both respond (click-through works).
6. Switch Spaces and enter a full-screen app: the pill is still there.
7. Right-click the pill: Quit works. Reopen it afterwards.

Clean up the fake session: `rm ~/.claude/island/sessions/shake-test.json`

If hover does not fire while another app is frontmost, stop and report it; the fix is an AppKit tracking area with `.activeAlways` on the hosting view, which is a design change to this file.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat: island window, views and pet"
```

---

### Task 7: End-to-end check against real sessions

**Files:** none created. This task verifies the spec's success criteria and fixes what it finds.

- [ ] **Step 1: Real alert.** In a new Terminal `claude` session, send a prompt and switch to another app. Expected: the island shakes within about a second of Claude finishing; the row reads Done.

- [ ] **Step 2: Permission alert.** Ask that session to run a command that needs approval. Expected: shake, row reads Needs you. Approve it. Expected: row returns to Working after the tool runs.

- [ ] **Step 3: Jumps.** Click the row for each host that is installed on this Mac and record the result:

| Host | Expected |
|---|---|
| Terminal.app | The exact tab comes forward (approve the one-time Automation prompt) |
| iTerm2 | The exact session comes forward |
| VS Code / Cursor | The window with that folder comes forward |
| Ghostty / Warp | The app comes forward |
| Claude desktop app | The app comes forward |

- [ ] **Step 4: Session end.** Exit a CLI session with `/exit`. Expected: its row disappears. Then kill a session's terminal window outright. Expected: its row disappears within a few seconds.

- [ ] **Step 5: Subagents.** Ask a session to use a subagent for a small task. Expected: no shake when the subagent finishes, one shake when the main session stops.

- [ ] **Step 6: Launch at login.** `ls ~/Library/LaunchAgents/com.claudeisland.app.plist` exists. Log out and in (or ask the user to confirm at next login): the island appears on its own.

- [ ] **Step 7: Commit any fixes**

```bash
git add -A && git commit -m "fix: issues found in end-to-end check"
```

Report to the user: which jump targets reached the exact tab, which only raised the app, and whether desktop-app sessions can be focused more precisely than raising the app.
