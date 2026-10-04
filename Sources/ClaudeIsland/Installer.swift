import Foundation

enum Installer {
    static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "Notification", "SessionEnd"]

    private static func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("claude-island\" hook")
    }

    /// Only an installed app bundle may be wired into hooks; a build-folder binary disappears on `swift package clean`.
    /// The guard makes the hook a silent no-op if the app is later deleted without uninstalling.
    static func hookCommand(exe: String) -> String? {
        guard exe.contains(".app/Contents/MacOS/") else { return nil }
        return "[ -x \"\(exe)\" ] && \"\(exe)\" hook || true"
    }

    /// Keeps the first backup: a later run must not replace the pristine copy with an already-modified file.
    @discardableResult
    static func backupIfAbsent(_ file: URL) throws -> URL {
        let backup = file.appendingPathExtension("island-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: file, to: backup)
        }
        return backup
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
        do {
            let backup = try backupIfAbsent(Paths.settings)
            print("Backup: \(backup.path)")
            let data = try JSONSerialization.data(withJSONObject: settings,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Paths.settings, options: .atomic)
        } catch {
            fail("Could not update settings: \(error.localizedDescription)")
        }
    }

    static func install() -> Never {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
              let command = hookCommand(exe: exe) else {
            fail("Run install from the app bundle (scripts/bundle.sh builds it), not from a build folder. Nothing was changed.")
        }
        writeSettings(merge(readSettings(), command: command))

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
