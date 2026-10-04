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
        sessions = Self.visible(Self.load(from: dir), hostHasOpenWindow: WindowCheck.hasOpenWindow)

        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            src.setEventHandler { [weak self] in self?.reload() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
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

    /// A session with no terminal lives in a windowed app (the Claude desktop app). Closing that window leaves
    /// the session's process running, so hide its row until the window is open again.
    static func visible(_ sessions: [Session], hostHasOpenWindow: (String) -> Bool) -> [Session] {
        var cache: [String: Bool] = [:]
        return sessions.filter { s in
            guard s.tty == nil, let host = s.hostBundleId else { return true }
            if cache[host] == nil { cache[host] = hostHasOpenWindow(host) }
            return cache[host] ?? true
        }
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
        let new = Self.visible(Self.load(from: dir), hostHasOpenWindow: WindowCheck.hasOpenWindow)
        guard new != sessions else { return }
        if Self.shouldAlert(old: sessions, new: new) { alertTick += 1 }
        sessions = new
    }

    private func prune() {
        for s in Self.load(from: dir) where !Self.isAlive(s.pid) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id).json"))
        }
    }

    func clearAttention(_ s: Session) {
        var c = s
        c.attention = false
        try? Session.encoder.encode(c).write(to: dir.appendingPathComponent("\(s.id).json"), options: .atomic)
    }
}
