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

        func set(_ state: SessionState, attention: Bool) {
            s.state = state
            s.attention = attention
            s.updatedAt = now
        }
        switch e.hookEventName {
        case "UserPromptSubmit", "PostToolUse":
            if s.state != .working { set(.working, attention: false) }
        case "Stop":
            if s.state != .done { set(.done, attention: true) }
        case "Notification":
            switch e.notificationType {
            // nil: a Claude Code version that does not say why it notified; better to alert than to miss a prompt.
            case nil, "permission_prompt", "elicitation_dialog":
                set(.needsYou, attention: true) // every prompt alerts, even a second one in a row
            case "idle_prompt":
                // Stop does not fire on Esc or an API error; the idle reminder is how we learn it stopped.
                if s.state == .working { set(.done, attention: true) }
            default:
                break
            }
        default:
            break
        }
        return s
    }
}
