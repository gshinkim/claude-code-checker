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
