# Claude Island: design

Date: 2026-10-04

## Purpose

Claude Code sessions run in other windows, so it is easy to miss when one
finishes or is waiting for a permission or an answer. Claude Island is a small
always-visible element at the top center of the MacBook screen that shows every
running Claude Code session, alerts when one stops, and jumps to it on click.

Personal tool for one Mac. No App Store, no settings UI.

## Success criteria

- A session finishing its turn or asking for permission produces a visible
  alert within about a second, whatever window is in front.
- Hovering the island lists all live sessions with their state.
- Clicking a session brings its window forward.
- Works for the `claude` CLI in terminals and for the Claude desktop app
  (priority), and for editor-integrated terminals.
- Installing does not damage existing entries in `~/.claude/settings.json`.

## Behavior

### Collapsed

- A black pill around the notch, extending slightly on each side and below it.
- Shows the pet and a count of sessions needing attention (hidden when zero).
- On a screen with no notch, sits at the top center of the main screen.
- Visible on every Space and over full-screen apps.

### Expanded

- Hovering the pill expands it into a panel: pet on the left, one row per
  session. Moving the mouse away collapses it.
- Row contents: project folder name (last path component of `cwd`), host app
  name, state, time since the state changed.

### States

| State | Meaning | Entered on |
|---|---|---|
| idle | Session exists, nothing happening yet | `SessionStart` |
| working | Claude is busy | `UserPromptSubmit`, `PostToolUse` |
| done | Claude finished its turn | `Stop` |
| needsYou | Waiting on a permission or an answer | `Notification` of type `permission_prompt` or `elicitation_dialog` (or with no type) |

- `SessionEnd` removes the session.
- `SubagentStop` is not hooked; subagents never alert.
- Every such `Notification` alerts, including a second one in a row.
- The idle reminder (`idle_prompt`) on a `working` session marks it `done` with
  an alert: `Stop` does not fire on Esc or an API error, so this is how a
  stalled session is noticed. On any other state it is ignored, so a done
  session does not alert twice.
- Other notification types (for example `auth_success`) are ignored.

### Alert

- On entering `done` or `needsYou`, the island shakes horizontally for about
  0.5 s and the pet shakes its head.
- The row stays highlighted (attention flag) until the row is clicked or the
  session returns to `working`.
- No sound.

### Jump

Clicking a row clears its attention flag and focuses the session:

| Host | Action |
|---|---|
| Terminal.app | AppleScript: select the tab whose tty matches, activate |
| iTerm2 | AppleScript: select the session whose tty matches, activate |
| VS Code, Cursor | Open `cwd` with that editor, which focuses its existing window |
| Anything else, including the Claude desktop app | Activate the owning app |

macOS asks once for Automation permission for Terminal.app and iTerm2. If the
scripted jump fails, fall back to activating the app.

### Housekeeping

- A session whose recorded process is no longer alive is removed.
- Right-clicking the pill shows a menu with Quit.

### Out of scope

Sounds, settings window, themes, suppressing the alert when the session's
window is already frontmost, exact-session focus inside the Claude desktop app
(investigated during the build; activating the app is the committed behavior).

## Architecture

One Swift package, one executable, `claude-island`, with subcommands:

- no arguments: run the island app
- `hook`: called by Claude Code hooks
- `install` / `uninstall`: manage hooks and launch at login

### Units

**HookCommand.** Reads the hook event JSON from stdin. Uses `session_id`,
`hook_event_name`, `cwd`, and the notification type. Finds the host by walking
parent processes: the Claude Code process id, its tty, and the owning app's
bundle id; also reads `TERM_PROGRAM`. Applies the state mapping and atomically
writes `~/.claude/island/sessions/<session_id>.json`, or deletes it on
`SessionEnd`. Always exits 0 and prints nothing, so it can never block or
pollute a session. Must be fast, since `PostToolUse` runs it on every tool call.

**Session file.**

```json
{
  "id": "…", "cwd": "/path", "state": "done", "attention": true,
  "updatedAt": "2026-10-04T12:00:00Z",
  "pid": 123, "tty": "/dev/ttys004",
  "hostBundleId": "com.apple.Terminal", "hostName": "Terminal"
}
```

**StateMapping.** Pure function `(previous session?, event) -> session or
removal`. Holds all the rules in the States section. No I/O.

**SessionStore.** Watches the sessions directory, decodes files into an
observable sorted list (attention first, then most recent), and every few
seconds removes files whose `pid` is dead. Clearing attention on click rewrites
that file.

**IslandWindow.** Borderless non-activating `NSPanel` above the menu bar, on
all Spaces. Positions itself from the screen's notch geometry, repositions on
screen changes. Hosts the SwiftUI views: pill, expanded list, shake, pet.

**PetView.** The Claude starburst with two eyes, drawn in SwiftUI. Idle bob
and head-shake animations.

**Jumper.** `(session) -> focus`, per the Jump table.

**Installer.** Refuses to run from outside an app bundle. Backs up `~/.claude/settings.json` (the first backup is never overwritten), then merges hook entries
for `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `Notification`,
`SessionEnd`, each running `<absolute path>/claude-island hook`, guarded so it is a silent no-op if the app has been deleted. Idempotent:
running it twice adds nothing. Preserves every existing key and hook.
`uninstall` removes only its own entries. Also writes or removes a LaunchAgent
plist for launch at login.

### Packaging

Only the command-line tools are installed (no Xcode), so a script runs
`swift build -c release` and wraps the binary in a minimal `.app` bundle with
`LSUIElement` set, so there is no Dock icon.

### Data flow

Claude Code event -> `claude-island hook` -> session file -> SessionStore
notices the change -> views update; a transition into `done` or `needsYou`
triggers the shake.

Files rather than a local server: no port, nothing fails when the app is not
running, and the list survives an app restart.

## Error handling

- Hook: any failure is swallowed; exit 0.
- Unreadable or partial session file: skipped.
- Missing or malformed `settings.json` on install: stop with a message, change
  nothing.
- Jump failure: fall back to activating the host app.

## Testing

- Automated: `StateMapping` (every row of the States table, the idle-reminder
  rule, attention clearing) and the `Installer` merge (preserves existing
  hooks, idempotent, uninstall removes only its own).
- Manual, against real sessions: notch placement, hover, shake, each jump
  target.

## Risks to check first in the build

1. Whether hooks in `~/.claude/settings.json` fire for Claude desktop app
   sessions. If not, desktop sessions cannot be tracked by this design.
2. Whether a test framework is available with command-line tools only. If not,
   the automated checks run as a `claude-island selfcheck` subcommand.
