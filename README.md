# cmux-bus

> Native multi-agent message bus for [cmux](https://cmux.com) — coordinate
> Claude Code, Codex CLI and other terminal agents across panes via an
> event-sourced JSONL log.

`cmux-bus` is a tiny, cmux-native coordination protocol for multiple AI
coding agents working side by side in adjacent panes. It gives them a
shared message bus, structured handoffs, file-ownership claims, and a
clean escalation path back to the human.

No daemon. No HTTP server. No MCP layer. No Node or Python. Just
~4 bash scripts, `jq`, and the `cmux` CLI you already have.

## Why

Most multi-agent setups today are tmux-based and ship as orchestrators
(agent-of-empires, CAO, ccmanager, agentic-tmux, multi-agent-shogun,
agent-deck, batty…). That's great if you live in tmux. If you live in
**cmux**, you have a richer native API (sidebar, browser, surfaces,
notifications, socket control) and don't need a heavy orchestrator on top
— you need a thin protocol that uses what cmux already gives you.

`cmux-bus` is that thin protocol. It does one thing: lets two agents pass
work to each other reliably without stepping on each other's files, with
an audit trail you can inspect with `cat`.

## Requirements

- [cmux](https://cmux.com) (uses `CMUX_SURFACE_ID`, `cmux send`,
  `cmux send-key`, `cmux surface-health`)
- `bash` 3.2+ (macOS default works, no Homebrew bash needed)
- `jq` 1.6+

## Install

```sh
git clone https://github.com/0xNekr/cmux-bus.git
cd cmux-bus
./install.sh
```

The installer symlinks all `bin/agent-*` scripts into `~/.local/bin`
(create it if missing). Updates are then a `git pull` away.

If Claude Code is detected (`~/.claude/rules/` exists), it also installs
`agents-protocol.md` there so Claude auto-loads the protocol context at
session start.

## Quick start

In a cmux workspace with two panes (e.g. one running `claude`, one
running `codex`), run this once in each pane:

```sh
# Pane A (Claude)
agent-init claude

# Pane B (Codex)
agent-init codex
```

That's the bootstrap. Each pane registers its `CMUX_SURFACE_ID` in
the resolved bus `agents.json`, the bus file is created, and an `AGENTS.md`
is written from `templates/AGENTS-block.md` in the current directory so any
agent starting fresh there sees the protocol.

By default, the bus is scoped to the current cmux workspace:

```txt
${XDG_STATE_HOME:-$HOME/.local/state}/cmux-bus/workspaces/<cmux-workspace-id>/
```

That means multiple git worktrees open inside the same cmux workspace share
one bus. The mirror case also holds: when the **same folder** is open in
several cmux workspaces at once (e.g. `Linear`, `Infra`, `Breeve` all on one
repo), each workspace gets its **own separate bus** — agents never collide on a
shared `.agents/agents.json`, and a signal stays inside the workspace it was
sent from. Resolution is bound to the calling pane's `CMUX_WORKSPACE_ID`
(falling back to the caller's workspace via `cmux identify`, never the focused
one), so a background agent always lands on its own workspace bus.

To force the old folder-local behavior for a command, use `--scope repo`; to
make that persistent in a shell, export `AGENT_BUS_SCOPE=repo`.

In workspace scope, `agent-init` also writes a small `.agents/` stub in the
current folder. The stub is deliberately not a bus; it tells agents to use
`agent-inbox` and `agent-send` instead of reading `.agents/agents.json` by
hand. If a closed legacy repo bus is present, only the legacy bus files are
archived to `.agents.repo-legacy-<timestamp>/`; non-bus content such as local
skills under `.agents/skills/` is left in place. If the legacy repo bus still
has open threads, `agent-init --scope workspace` refuses until those threads
are closed or migrated.

Now from Claude:

```sh
ID=$(agent-send codex handoff --paths "src/api.ts,src/types.ts" \
  "Refactor src/api.ts to use the new Result type")
echo "$ID"   # 8-char id, e.g. 'a3f81c92'
```

Codex's pane receives a wake-up signal in its prompt:
`new handoff id=a3f81c92 from=claude`. It runs `agent-inbox`, sees the
open thread, does the work (without anyone else touching `src/api.ts` or
`src/types.ts`), and closes the loop:

```sh
agent-done a3f81c92 "done in commit abc123. Tests passing."
```

Claude's pane receives a wake-up; `agent-inbox` is now clean.

## Commands

| Command | What it does |
|---|---|
| `agent-init [--scope repo\|workspace] [--bus-dir DIR] <name>` | Bootstrap or refresh this bus for `<name>`. Creates the resolved bus dir, registers your `CMUX_SURFACE_ID`, writes `PROTOCOL.md` and `AGENTS.md`, and purges stale entries from previous sessions. |
| `agent-send [--scope repo\|workspace] [--bus-dir DIR] <to> <type> [flags] <body>` | Append event(s) and signal recipient(s). Types: `ask`, `handoff`, `done`, `block`, `ack`. Flags: `--ref ID`, `--paths "p1,p2"`, `--status STATUS`. For `ask`, `<to>` may be `all` or comma-separated names (`claude,deepseek`); this fans out into one thread per peer. Refuses unknown refs and stale recipients. |
| `agent-inbox [--scope repo\|workspace] [--bus-dir DIR] [--json] [--no-stale\|--only-stale] [--no-stuck\|--only-stuck] [--stuck-after MIN]` | List open threads addressed to you, grouped by thread root. Threads whose sender is no longer registered appear with `[stale]`. Threads whose last event is `in_progress` and older than the stuck threshold (default 10 min, configurable via `AGENT_BUS_STUCK_AFTER_MIN` env) appear with `[stuck Xm]`. |
| `agent-roster [--scope repo\|workspace] [--bus-dir DIR] [--json]` | List the agents registered in the resolved bus and tell you, up front, which one you are (resolved from `CMUX_SURFACE_ID`). Marks your own row `(you)` and flags each peer `live`/`stale` by presence in `surface-health`. Read-only. |
| `agent-done [--scope repo\|workspace] [--bus-dir DIR] <id> [body]` | Close a thread by appending a `done` event referencing `<id>`. |
| `agent-cancel [--scope repo\|workspace] [--bus-dir DIR] <id> [--force] [reason]` | Drop a thread by appending a `block` event to `user` with `status: blocked`. Refuses if the thread is already done/blocked unless `--force`. |
| `agent-resume [--scope repo\|workspace] [--bus-dir DIR] <id> [--force] [body]` | Re-open a stuck/crashed thread by appending a fresh `handoff` to its **original recipient**. Default body: `RESUME: <previous>`. Refuses if the thread is already done/blocked unless `--force`. |
| `agent-doctor [--scope repo\|workspace] [--bus-dir DIR]` | Validate the resolved bus and registry without mutating anything. Reports malformed JSONL, schema errors, duplicate ids, orphan refs, and open/stale/stuck thread counts. |
| `agent-repair [--scope repo\|workspace] [--bus-dir DIR] [--dry-run]` | Repair the resolved `bus.jsonl` when old malformed records contain raw newlines. Dry-run reports what would change; write mode creates a timestamped backup before replacing the bus. |
| `agent-guard [--scope repo\|workspace] [--bus-dir DIR] check [--json] [--staged] [--agent NAME\|--all] [PATH...]` | Detect files that overlap `paths_claimed` by open threads. By default it ignores claims owned by the current registered surface; use `--agent NAME` outside cmux or `--all` to include every claim. `--staged` checks staged git paths for pre-commit usage. |
| `agent-guard [--scope repo\|workspace] [--bus-dir DIR] install [--force]` | Install a git pre-commit hook that runs `agent-guard check --staged` and blocks commits touching files claimed by another open thread. |
| `agent-rpc [--scope repo\|workspace] [--bus-dir DIR] [--timeout SEC] [--interval SEC] [--status done\|blocked\|final] [--json] <agent> <body...>` | Send one `ask` to a single agent, wait for the thread to finish, and print the final body. Use `--json` to print the final event object. A blocked final event is printed and exits non-zero. |
| `agent-playbook [--scope repo\|workspace] [--bus-dir DIR] run <name-or-path> [KEY=VALUE...]` | Run a JSON workflow from `<bus-dir>/playbooks/<name>.json` or an explicit path. Supports `send`, `wait`, `rpc`, and `print` steps with `{{variable}}` interpolation. |
| `agent-synthesize [--scope repo\|workspace] [--bus-dir DIR] [--agent NAME] [--timeout SEC] [--interval SEC] [--json] <id...>` | Wait for multiple threads to finish, bundle their final replies, and ask the synthesis agent (default `claude`) for consensus, disagreements, and a recommendation. |
| `agent-thread [--scope repo\|workspace] [--bus-dir DIR] [--json] <id>` | Show the full event history for any event id in a thread. |
| `agent-watch [--scope repo\|workspace] [--bus-dir DIR] [--once] [--me] [--full] [--no-color] [--clear] [--lines N] [--interval SEC]` | Watch bus events as they are appended. Use `--once` for a snapshot, `--me` to show only events involving the current registered surface, `--full` to avoid body truncation, and `--clear` to truncate the resolved `bus.jsonl` before watching. |
| `agent-wait [--scope repo\|workspace] [--bus-dir DIR] [--timeout SEC] [--interval SEC] [--status done\|blocked\|final] <id>` | Wait for a thread to reach `done`, `blocked`, or either final state. Prints the final event as JSON and exits non-zero on timeout or unknown id. |

`agent-guard` treats `paths_claimed` as meaningful on open `handoff` events.
Claims use Bash pattern matching, so glob characters such as `*`, `?`, and
`[...]` are active. `**` is not recursive. A leading `./` is ignored when
comparing paths. New events include `cwd`, so claims are resolved relative to
the worktree where they were created when a workspace-scoped bus is shared by
multiple folders.

`agent-playbook` files are JSON and live well as local runtime state under
`<bus-dir>/playbooks/`. `send.paths` uses the same comma-separated string
format as `agent-send --paths`. `send.save` stores the event id directly;
`wait.save` and `rpc.save` expose `<name>_id`, `<name>_status`, and
`<name>_body`.
Example:

```json
{
  "steps": [
    {"rpc": {"to": "claude", "body": "Review {{task}}", "save": "review"}},
    {"rpc": {"to": "deepseek", "body": "QA {{task}}\nClaude said: {{review_body}}", "save": "qa"}},
    {"print": "Claude: {{review_body}}\nDeepSeek: {{qa_body}}"}
  ]
}
```

Run it with:

```sh
agent-playbook run review-qa task="add agent-broadcast"
```

Use `agent-synthesize` after broadcast asks when you want one decision instead
of several raw replies:

```sh
ids=$(agent-send claude,deepseek ask "Pick the next feature")
agent-synthesize $ids
```

## Recovery — what to do when a peer crashes

If your peer pane is interrupted mid-task (auto-reviewer denied a
command, the process died, the human Ctrl+C'd it…), the thread is left
declared `in_progress` with no follow-up. After ~10 minutes, your
`agent-inbox` will tag it `[stuck Xm]`. You then have three deliberate
choices:

```sh
# 1. The peer is back and ready — just re-ping the same thread
agent-resume <thread-id>

# 2. You changed your mind — drop the thread cleanly with a paper trail
agent-cancel <thread-id> "blocked on <reason>, dropping"

# 3. You took over the work yourself — close it manually
agent-done <thread-id> "did it myself, see commit abc123"
```

The bus is never mutated retroactively — every action is a new event
appended to the chain. Past state is always inspectable.

## Broadcast asks

Use broadcast when you want independent opinions from multiple agents:

```sh
agent-send all ask "Review this approach and reply GO/NO-GO"
agent-send claude,deepseek ask "Compare these two options"
```

Broadcast is intentionally a fan-out: it appends one normal root event per
recipient and returns one id per line. The on-disk schema stays unchanged
(`to` is always a string), so each recipient owns a separate thread and can
ack, block, or done without affecting the others.

Broadcast is only supported for `ask`. `handoff` is deliberately excluded
because broadcasting the same `paths_claimed` would make file ownership
ambiguous.

## Event schema

Every line in the resolved `bus.jsonl` is one JSON object:

```json
{
  "id":             "8-char id",
  "ts":             "ISO-8601 UTC",
  "from":           "agent name",
  "to":             "agent name (or 'user')",
  "type":           "ask|handoff|done|block|ack",
  "ref":            "id of parent event, or null",
  "status":         "open|in_progress|done|blocked",
  "paths_claimed":  ["glob", ...],
  "cwd":            "sender working directory",
  "body":           "free text"
}
```

The bus is **append-only**. State is event-sourced: the effective status
of a thread is whatever the last event in the chain declares. See
[`PROTOCOL.md`](./PROTOCOL.md) for the full spec.

Writers validate each event as a single-line JSON object and serialize
appends with `<bus-dir>/bus.lock`, so concurrent agents cannot interleave
partial JSON lines.

## Workspace isolation

The default bus lives at cmux-workspace scope, so multiple folders or git
worktrees opened in the same cmux workspace share one bus. This matches the
way adjacent panes collaborate on one active effort.

Use repo scope when you need folder isolation:

```sh
agent-init --scope repo codex
agent-inbox --scope repo
```

For a persistent folder-local default in one shell:

```sh
export AGENT_BUS_SCOPE=repo
```

`AGENT_BUS_DIR=/path/to/bus` is an escape hatch for explicit custom storage.

If `agent-send` says a recipient is unknown or stale, do not fall back to
`cmux send`. Have the peer run `agent-init <name>` in its current pane, or
rerun with `--scope repo` only when you intentionally want the folder-local
bus.

## Surface lifecycle

cmux surface IDs are tied to a live pane. If you close a pane, restart
cmux, or recreate a split, the old surface ID becomes stale.

- `agent-init` auto-purges stale entries on every run
- `agent-send` refuses to signal a stale recipient (no silent void)
- `agent-inbox` flags threads opened by stale senders (`[stale]`)

The bus is never auto-rewritten. Cleanup of stale threads is a deliberate
human action via `agent-done <id>`.

## Routing defaults

A loose convention, not enforcement:

- **Claude** — design, critique, broad exploration, multi-file refactor
- **Codex** — CLI diagnostics, scripts, tests, bisect, hypothesis checks

Override freely based on what each agent is best at for the task at hand.

## What this is not

- Not an orchestrator (no scheduler, no worktree management)
- Not a tmux thing (uses cmux's native API; tmux users have plenty of
  better-fit projects)
- Not a daemon, broker, or service
- Not opinionated about which agents you run — anything that runs in a
  terminal and can read/write files works

## Comparison

| | cmux-bus | cmuxlayer | agent-of-empires | CAO |
|---|---|---|---|---|
| Multiplexer | cmux native | cmux native | tmux | tmux |
| Transport | JSONL file + cmux signal | MCP server (Node) | tmux send-keys | HTTP MCP server (Python) |
| Structured handoffs | ✅ | ❌ | partial | ✅ |
| File ownership claims | ✅ | ❌ | ❌ | ❌ |
| Append-only audit trail | ✅ | partial (telemetry) | ❌ | ❌ |
| Dependencies | bash + jq | Node + npm | Rust binary | Python 3.10+ |
| Order of magnitude (LOC) | hundreds | thousands | tens of thousands | thousands |

## License

[Apache-2.0](./LICENSE)
