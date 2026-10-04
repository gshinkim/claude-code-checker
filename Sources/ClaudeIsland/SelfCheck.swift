import Foundation

enum SelfCheck {
    static var failures = 0

    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "ok   " : "FAIL ", name)
        if !ok { failures += 1 }
    }

    static func run() -> Never {
        checkStateMapping()
        checkHostDetector()
        checkInstaller()
        checkSessionStore()
        checkJumper()
        checkPet()
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

        var seen = needs; seen?.attention = false
        let t2 = Date(timeIntervalSince1970: 5000)
        let second = step("Notification", "permission_prompt", from: seen, at: t2)
        check(second?.attention == true && second?.updatedAt == t2, "a second permission prompt alerts again")
        check(step("Notification", "auth_success", from: working) == working, "auth notification does not alert")
        check(step("Notification", "elicitation_dialog", from: working)?.state == .needsYou, "a question from Claude needs you")
        let stalled = step("Notification", "idle_prompt", from: working)
        check(stalled?.state == .done && stalled?.attention == true, "idle reminder while working means it stopped (Esc, API error)")

        check(StateMapping.isSafeId("abc-123_X"), "normal id is safe")
        check(!StateMapping.isSafeId("../../evil"), "path characters are rejected")
        check(!StateMapping.isSafeId(""), "empty id is rejected")

        let json = #"{"session_id":"a","hook_event_name":"Notification","cwd":"/x","notification_type":"idle_prompt","extra":1}"#
        let decoded = try? JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
        check(decoded?.sessionId == "a" && decoded?.notificationType == "idle_prompt", "HookEvent decodes Claude Code JSON")
    }

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
            // Real layout: the Claude Code binary ships inside its own claude.app bundle.
            40: Proc(ppid: 30, tty: "??", comm: "/Users/you/Library/Application Support/Claude/claude-code/2.1.286/x/claude.app/Contents/MacOS/claude"),
            30: Proc(ppid: 20, tty: "??", comm: "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            20: Proc(ppid: 1, tty: "??", comm: "/Applications/Claude.app/Contents/MacOS/Claude"),
        ]
        let c = HostDetector.resolve(start: 40, table: desktop)
        check(c.tty == nil, "no tty in the desktop app")
        check(c.appPath == "/Applications/Claude.app", "Claude Code's own bundle is not mistaken for the host app")

        let d = HostDetector.resolve(start: 9, table: [9: Proc(ppid: 1, tty: "??", comm: "tmux")])
        check(d.appPath == nil && d.pid == 9, "no owning app is not an error")
    }

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

        check(Installer.hookCommand(exe: "/Users/you/Desktop/Dynamic_Island/.build/debug/claude-island") == nil,
              "refuses to wire hooks to a build-folder binary")
        let guarded = Installer.hookCommand(exe: "/Users/you/Applications/ClaudeIsland.app/Contents/MacOS/claude-island")
        check(guarded?.hasPrefix("[ -x ") == true && guarded?.hasSuffix("|| true") == true,
              "hook command does nothing if the app was deleted")
        check(same(Installer.strip(Installer.merge(existing, command: guarded ?? "")), existing), "strip recognises the guarded command")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("island-backup-\(getpid()).json")
        let bak = tmp.appendingPathExtension("island-backup")
        defer { try? FileManager.default.removeItem(at: tmp); try? FileManager.default.removeItem(at: bak) }
        try? Data("original".utf8).write(to: tmp)
        _ = try? Installer.backupIfAbsent(tmp)
        try? Data("modified".utf8).write(to: tmp)
        _ = try? Installer.backupIfAbsent(tmp)
        check((try? String(contentsOf: bak, encoding: .utf8)) == "original", "the first backup is never overwritten")

        let bare: [String: Any] = ["theme": "dark"]
        check(((Installer.merge(bare, command: cmd)["hooks"] as? [String: Any])?.count ?? 0) == Installer.events.count,
              "merge works with no hooks key")
        check(same(Installer.strip(Installer.merge(bare, command: cmd)), bare), "strip restores a file that had no hooks key")
    }

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

        var desktop = make("desktop", .working, attention: false, at: 1); desktop.hostBundleId = "app.closed"
        var desktopOpen = make("desktopOpen", .working, attention: false, at: 1); desktopOpen.hostBundleId = "app.open"
        var terminal = make("terminal", .working, attention: false, at: 1); terminal.hostBundleId = "app.closed"; terminal.tty = "/dev/ttys001"
        let shown = SessionStore.visible([desktop, desktopOpen, terminal, old]) { $0 == "app.open" }
        check(shown.map(\.id) == ["desktopOpen", "terminal", "old"],
              "a windowed app's sessions are hidden while its window is closed; terminal and unknown hosts stay")

        check(SessionStore.isAlive(getpid()), "own pid is alive")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run(); p.waitUntilExit()
        check(!SessionStore.isAlive(p.processIdentifier), "exited pid is not alive")
    }

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

    static func checkPet() {
        let pet = CGPoint(x: 800, y: 1100) // screen coordinates, y grows upward
        let right = PetView.eyeOffset(mouse: CGPoint(x: 1700, y: 1100), pet: pet)
        check(abs(right.width - 0.6) < 0.01 && abs(right.height) < 0.01, "eyes look right at a far-right cursor")
        let below = PetView.eyeOffset(mouse: CGPoint(x: 800, y: 100), pet: pet)
        check(abs(below.height - 0.5) < 0.01 && abs(below.width) < 0.01, "eyes look down at a cursor below")
        check(PetView.eyeOffset(mouse: pet, pet: pet) == .zero, "eyes are centered when the cursor is on the pet")
        let near = PetView.eyeOffset(mouse: CGPoint(x: 830, y: 1100), pet: pet)
        check(near.width > 0 && near.width < 0.2, "a nearby cursor moves the eyes only a little")
    }
}
