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
running `codex`), **from the workspace root in each pane**:

```sh
# Pane A (Claude), cwd = workspace root
agent-init claude

# Pane B (Codex), cwd = workspace root
agent-init codex
```

That's the bootstrap. Each pane registers its `CMUX_SURFACE_ID` in
`.agents/agents.json`, the bus file is created, and an `AGENTS.md` is
written from `templates/AGENTS-block.md` at the workspace root so any agent
starting fresh in this project sees the protocol. The `.agents/` directory
is runtime state — it is added to your `.gitignore` automatically and
should not be committed.

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
| `agent-init <name>` | Bootstrap or refresh this workspace for `<name>`. Creates `.agents/`, registers your `CMUX_SURFACE_ID`, writes `PROTOCOL.md` and `AGENTS.md`, updates `.gitignore`. Purges stale entries from previous sessions. |
| `agent-send <to> <type> [flags] <body>` | Append event(s) and signal recipient(s). Types: `ask`, `handoff`, `done`, `block`, `ack`. Flags: `--ref ID`, `--paths "p1,p2"`, `--status STATUS`. For `ask`, `<to>` may be `all` or comma-separated names (`claude,deepseek`); this fans out into one thread per peer. Refuses unknown refs and stale recipients. |
| `agent-inbox [--json] [--no-stale\|--only-stale] [--no-stuck\|--only-stuck] [--stuck-after MIN]` | List open threads addressed to you, grouped by thread root. Threads whose sender is no longer registered appear with `[stale]`. Threads whose last event is `in_progress` and older than the stuck threshold (default 10 min, configurable via `AGENT_BUS_STUCK_AFTER_MIN` env) appear with `[stuck Xm]`. |
| `agent-done <id> [body]` | Close a thread by appending a `done` event referencing `<id>`. |
| `agent-cancel <id> [--force] [reason]` | Drop a thread by appending a `block` event to `user` with `status: blocked`. Refuses if the thread is already done/blocked unless `--force`. |
| `agent-resume <id> [--force] [body]` | Re-open a stuck/crashed thread by appending a fresh `handoff` to its **original recipient**. Default body: `RESUME: <previous>`. Refuses if the thread is already done/blocked unless `--force`. |
| `agent-doctor` | Validate the local bus and registry without mutating anything. Reports malformed JSONL, schema errors, duplicate ids, orphan refs, and open/stale/stuck thread counts. |
| `agent-repair [--dry-run]` | Repair `.agents/bus.jsonl` when old malformed records contain raw newlines. Dry-run reports what would change; write mode creates a timestamped backup before replacing the bus. |
| `agent-guard check [--json] [--staged] [--agent NAME\|--all] [PATH...]` | Detect files that overlap `paths_claimed` by open threads. By default it ignores claims owned by the current registered surface; use `--agent NAME` outside cmux or `--all` to include every claim. `--staged` checks staged git paths for pre-commit usage. |
| `agent-guard install [--force]` | Install a git pre-commit hook that runs `agent-guard check --staged` and blocks commits touching files claimed by another open thread. |
| `agent-thread [--json] <id>` | Show the full event history for any event id in a thread. |
| `agent-watch [--once] [--me] [--full] [--no-color] [--lines N] [--interval SEC]` | Watch bus events as they are appended. Use `--once` for a snapshot, `--me` to show only events involving the current registered surface, and `--full` to avoid body truncation. |
| `agent-wait [--timeout SEC] [--interval SEC] [--status done\|blocked\|final] <id>` | Wait for a thread to reach `done`, `blocked`, or either final state. Prints the final event as JSON and exits non-zero on timeout or unknown id. |

`agent-guard` treats `paths_claimed` as meaningful on open `handoff` events.
Claims use Bash pattern matching, so glob characters such as `*`, `?`, and
`[...]` are active. `**` is not recursive. A leading `./` is ignored when
comparing paths.

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

Every line in `.agents/bus.jsonl` is one JSON object:

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
  "body":           "free text"
}
```

The bus is **append-only**. State is event-sourced: the effective status
of a thread is whatever the last event in the chain declares. See
[`PROTOCOL.md`](./PROTOCOL.md) for the full spec.

Writers validate each event as a single-line JSON object and serialize
appends with `.agents/bus.lock`, so concurrent agents cannot interleave
partial JSON lines.

## Workspace isolation

The bus lives in `.agents/` at your workspace root. Each project has its
own bus, registry, and protocol — they never see each other. A single
pane can participate in multiple workspaces; just `agent-init` in each.

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
