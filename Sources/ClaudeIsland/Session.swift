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
