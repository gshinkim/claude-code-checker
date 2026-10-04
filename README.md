# Claude Island

A Dynamic-Island-style status pill for Claude Code on macOS. It sits around the
MacBook notch, lists every running Claude Code session, and alerts you when one
finishes or is waiting for your input, so you stop missing prompts in other
windows.

- Hover the pill to see all sessions and their state: Working, Done, Needs you.
- When a session stops or asks for permission, the island shakes and the pet hops.
- Click a session to bring its window forward (exact tab in Terminal.app and iTerm2).
- The pet's eyes follow your cursor.

Works with the `claude` CLI in any terminal, editor terminals, and the Claude
desktop app.

## Requirements

- macOS 14 or later
- Swift toolchain (Xcode or the Command Line Tools)

## Install

```bash
scripts/bundle.sh
~/Applications/ClaudeIsland.app/Contents/MacOS/claude-island install
open ~/Applications/ClaudeIsland.app
```

`install` adds hook entries to `~/.claude/settings.json` (a backup is written to
`settings.json.island-backup` first; existing hooks are kept) and sets the app
to start at login. Only Claude Code sessions started afterwards are tracked.

## Uninstall

```bash
~/Applications/ClaudeIsland.app/Contents/MacOS/claude-island uninstall
```

Then quit the island (right-click the pill) and delete the app.

## How it works

One binary plays two roles. Claude Code hooks call `claude-island hook` on each
session event; it writes one small JSON file per session to
`~/.claude/island/sessions/`. The app watches that folder and draws the island.
There is no server and no network access.

## Checks

```bash
swift build && .build/debug/claude-island selfcheck
```

## Notes

- Hiding a desktop-app session while its window is closed uses two private
  window-server calls; if they are unavailable the row simply stays visible.
- Not affiliated with Anthropic.

## License

MIT. See [LICENSE](LICENSE).
