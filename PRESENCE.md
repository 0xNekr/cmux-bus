# Live agent counts in the native cmux sidebar

`agent-presence` adds one native status line per state: orange for explicit
questions/approvals, blue for work in progress, gray for idle agents. Zero counts
are dimmed. It preserves cmux's workspace selection, drag/reorder and complete
native right-click menu, including the rename dialog and close action.

```sh
agent-presence enable
# Existing terminal: run this in the foreground, or open a new cmux zsh terminal.
agent-presence watch
agent-presence status
agent-presence disable
```

Enable installs a runtime copy outside `Documents` and a marked, removable block
in `${ZDOTDIR:-$HOME}/.zshrc`. New cmux shells start the collector automatically.
One collector owns a file lock; other shells wait and take over if its shell
closes. Existing shells are not sent commands or restarted. Bash/fish users can
run `agent-presence watch` explicitly; automatic setup currently supports zsh.
Disable removes the startup block, stops managed collectors, and clears only
`agent-presence-*` status keys. It does not stop coding agents or change the bus.
The repo installer only makes the command available; enable is explicit.

## Performance and native behavior

The collector polls every two seconds over a persistent local cmux socket and
publishes only changed status lines. It never selects a workspace or rewrites a
sidebar definition. Workspace clicks stay entirely inside the native app.
The `cmuxOnly` socket security setting is preserved: the collector runs under a
cmux terminal shell, not launchd. No extra workspace or pane is needed.

If upgrading from the experimental custom sidebar, select **Default Workspaces**
in the sidebar button's right-click menu. Enable removes the old LaunchAgent.
The native sidebar also retains cmux's existing notification previews and
metadata. Selected-row colors follow cmux's native selection styling.

## Data and compatibility

- Verified with cmux 0.64.22 and Python 3.9+, macOS; no Python dependencies.
- Reads `~/.cmuxterm/*-hook-sessions.json`, a version-sensitive internal schema.
  Missing/malformed stores display **Suivi indisponible**, not zero agents.
- Reuses cmux's injected agent hooks. Agent configuration, permissions, the
  application bundle and notification state are unchanged.
- Matches sessions against live surfaces from `system.tree`: moving a terminal
  moves its count, and closed terminals disappear. Checks PID and process start
  time; uncertain identities are **unknown**, not idle. Counts one live session
  per terminal surface, not provider-internal subagents.
- Codex transcripts are read incrementally for lifecycle events, correcting
  stale native idle flags. Explicit `request_user_input` calls remain pending
  until their result. Async questions stay pending after `accepted:true` until
  a reply/new turn. Ordinary assistant prose is not classified as a question.
- Other integrated providers use the native hook lifecycle schema. Codex has
  been verified live; other lifecycle mappings have fixture coverage.
- Snapshot output contains IDs, providers and status, not conversation content.
  Graceful shutdown clears the collector's lines. A forced kill can leave old
  counts until another collector takes over; `status` includes `observedAt`.

Overrides: `--hook-dir`, `--state-dir`, `--socket`, `--zshrc`.
`CMUX_AGENT_HOOK_STATE_DIR` and `CMUX_SOCKET_PATH` supply the usual defaults.
`agent-presence once` collects and publishes once, then prints its snapshot.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/presence.py
```
