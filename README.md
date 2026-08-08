# AgentActivity

AgentActivity is a native macOS menu-bar-only app. Selecting its grid icon in the menu bar opens a compact annual heatmap for work completed with Cursor, Codex, Claude, GitHub, and other agents.

The app deliberately uses accessory activation and `LSUIElement`, so it does not appear in the Dock or open a normal app window.

The menu-bar button is hosted by `NSStatusItem` and opens a pre-sized, non-animated `NSPopover`. This keeps the first visible frame anchored under the status item instead of briefly presenting a small window in a screen corner.

## Activity sources

- **Cursor:** combines historical local agent transcripts with forward-looking hooks. The global hook uses Cursor's native `conversation_id` and `workspace_roots`, then resolves the supplied workspace to its Git repository root. Cursor does not expose historical personal IDE token totals, so missing values are shown as unavailable.
- **Codex:** uses the documented Codex App Server `thread/list` and `account/usage/read` methods. State-database-only pagination avoids scanning multi-gigabyte JSONL archives. Local Git commits are correlated by repository and session time window.
- **Claude:** combines historical local session timestamps and usage counters with forward-looking hooks. The global hook uses Claude's native `session_id` and `cwd`, including `CwdChanged` events, to follow the repository used by the session.
- **GitHub:** uses `gh api graphql` and the authenticated viewer's `contributionsCollection`. AgentActivity never reads or stores the GitHub token.
- **Others:** remains available for future providers and manually imported activity.

Commit-to-agent links are derived unless a provider supplies a verified commit association. Hook-driven activity uses the repository folder supplied by Cursor or Claude and records the current commit at selected lifecycle events. The **Choose repository folders…** action is only needed to correlate older transcript activity; the app never crawls Desktop or Documents automatically. Prompt text, response text, source code, commands, tool inputs/results, and credentials are not stored by AgentActivity. The official-source integration analysis is in [`Docs/activity-data-sources.md`](Docs/activity-data-sources.md).

## Cursor and Claude hooks

The installed user-level hook configs are:

- Cursor: `~/.cursor/hooks.json`
- Claude: `~/.claude/settings.json`

Both invoke `script/agent_activity_hook.sh`. The receiver stores privacy-minimized JSON Lines in `~/Library/Application Support/AgentActivity/hooks/`, with one file per provider and a single 25 MB rotated backup. Each record is limited to lifecycle metadata, provider session IDs, repository roots, tool/agent labels, counters, and optional Git HEAD hash/time/line totals. It does not write hook stdout, so `SessionStart` and prompt hooks do not add content to the agent's context. A native Claude transcript-path check prevents Cursor's optional Claude-settings compatibility from double-counting the same session under both tabs.

Start a new Cursor or Claude session after changing a hook config. Future sessions use provider-native repository paths automatically. Historical imports continue to recognize Cursor's `~/.cursor/projects/*/agent-transcripts/` and Claude's `~/.claude/projects/` storage patterns.

## Build and run

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM executable, stages `dist/AgentActivity.app`, and opens the fresh bundle. The Codex Run action is wired to the same script.

## Verify

```bash
swift test
./script/build_and_run.sh --verify
```

The app shows deterministic data immediately while a source performs its first background import, then caches the real result for the current run. Use the replay button to refresh a source.
