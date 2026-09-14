# Live agent counts in the cmux sidebar

`agent-presence` adds a native sidebar with one line per state: orange for an
explicit question/approval, blue for work in progress, gray for idle agents.
Zero counts are dimmed. Click a count to select that workspace and focus a
matching terminal; drag workspace rows to reorder them.

```sh
agent-presence enable
cmux sidebar select agents-workspaces
agent-presence status
agent-presence disable
```

Enable installs a user LaunchAgent and a runtime copy outside `Documents`.
It starts at login and polls every two seconds. Disable stops the service;
choose **Default Workspaces** from the sidebar button's right-click menu to
return to the native view. It does not stop or restart any coding agents.
Installation is independent of `agent-bus enable/disable`. Running the repo
installer only makes the command available; enabling the service is explicit.

## Data and compatibility

- Tested with cmux 0.64.22, Python 3.9+, macOS. No Python dependencies.
- Reads cmux's existing `~/.cmuxterm/*-hook-sessions.json` files. These are an
  internal, version-sensitive adapter, not a public stable API. A malformed or
  missing store is shown as **Suivi indisponible**, not as zero agents.
- Reuses hooks installed/injected by cmux. Does not modify agent configuration,
  permissions, notification state, the bus, or the application bundle.
- Reads only to derive state; generated files contain surface/session IDs,
  providers, counts and status, not prompts, tool arguments or assistant text.
- The background service makes **no socket calls**, preserving `cmuxOnly`
  security. The sidebar joins session surface IDs to its live `w.tabs` data.
  Closed terminals disappear and moving a terminal moves its count immediately.
- Checks process existence and start time to reject stale/reused PIDs. A process
  that cannot be verified is **unknown**, never silently assumed idle. One live
  session per surface is counted; provider-internal subagents are not terminals.
- Codex turn boundaries are also read incrementally from its transcript,
  correcting stale native idle flags. Explicit `request_user_input` calls are
  pending until their result. Async questions stay pending after `accepted:true`
  until a user reply/new user turn; ordinary assistant prose is not classified.
  Native needs-input/error states take priority if newer than transcript events.
- Other hook-integrated providers use the shared native lifecycle schema.
  Codex has been verified live; Claude/provider lifecycle mappings are covered by
  fixtures. Unintegrated agents cannot be counted reliably: enable their official
  cmux hooks first. No claim is made to infer arbitrary questions from prose.
- After 15 seconds without a collector heartbeat, the view says **Suivi
  interrompu**. Counts are never frozen silently if the service exits.

Overrides: `--hook-dir`, `--state-dir`, `--sidebar`, `--cmux`. Defaults respect
`CMUX_AGENT_HOOK_STATE_DIR`. For a read-only collection into temporary output:

```sh
agent-presence once --sidebar /tmp/presence.swift --state-dir /tmp/presence-state
PYTHONDONTWRITEBYTECODE=1 python3 tests/presence.py
```

The generated Swift uses inline expressions because local bindings inside
repeated conditional views in cmux 0.64 validate but render empty. Files are
replaced atomically, with exclusive service locking and ownership checks.
