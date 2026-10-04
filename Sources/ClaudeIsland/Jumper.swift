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
