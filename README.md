# cmux-bus

## Independent agents in one workspace

Run this from any pane **before launching independent AI sessions**:

```sh
agent-bus disable       # all panes in this cmux workspace
agent-bus status        # enabled / disabled
agent-bus enable        # explicitly allow coordination again
```

Disabling persists across commands and new panes in the same workspace. It
blocks registration, messaging, spawning, recovery and bus reads (exit code 4),
including attempts through repo scope or an explicit bus directory. Other
workspaces, including those on the same repository, remain enabled. The command
always targets the caller's workspace, ignoring bus environment overrides.
`agent-bus status --quiet` exits 0 when enabled and 1 when disabled.

Panes, agent processes, worktrees and bus history are retained. The canonical
workspace watchdog and notifier are stopped; running bus loops check the switch
on their next iteration. An operation already in flight or text already injected
cannot be recalled. Existing AI conversations may remember their old role: tell
them to continue independently. Bus/lead rules do not apply while disabled;
never re-enable or bypass the switch without an explicit user request.

After `enable`, run `agent-init <name>` in participating panes to resume. Existing
threads are retained, and an independent `agent-notify disable` preference is
preserved. Enabling alone does not launch workers or restart services.


> Native multi-agent message bus for [cmux](https://cmux.com) — coordinate
> Claude Code, Codex CLI and other terminal agents across panes via an
> event-sourced JSONL log.

`cmux-bus` is a tiny, cmux-native coordination protocol for multiple AI
coding agents working side by side in adjacent panes. It gives them a
shared message bus, structured handoffs, file-ownership claims, and a
clean escalation path back to the human.

Bash scripts, `jq`, and the `cmux` CLI, with optional Git worktrees for isolated
workers. No HTTP server, MCP layer, Node or Python runtime.

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
(create it if missing). Updates are then a `git pull` away (or `agent-update`).

If Claude Code is detected (`~/.claude/rules/` exists), it also installs
`agents-protocol.md` there so Claude auto-loads the protocol context at
session start.

Add `--guard` to also enable strict-lead enforcement on this machine:

```sh
./install.sh --guard          # = install + agent-lead-guard install
```

### Using it across your repos / sharing with a team

Each developer installs cmux-bus **once** (`clone + ./install.sh`); the symlinks
point at their own clone, so every repo and cmux workspace on that machine picks
up the latest commands automatically. The per-bus `PROTOCOL.md`/`AGENTS.md` are
snapshots copied by `agent-init` — re-run it (or `agent-update`) to refresh an
old bus.

A repo can **ship its own governance** so cloners inherit it automatically:

- **Spawn policy** — commit `.cmux-bus/policy.json` (see [Spawn call
  policy](#spawn-call-policy-who-may-create-whom)). Any cloner with cmux-bus
  resolves it at runtime; repo rules override the user's.
- **Strict-lead enforcement** — run `agent-lead-guard install --project` and
  commit the resulting `.claude/settings.json`. The hook command is written
  PATH-relative and fail-safe, so cloners who have cmux-bus get the enforcement
  and cloners who don't are unaffected (it no-ops).

So a "bus-governed" repo just commits two small files; teammates only need
cmux-bus installed.

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
| `agent-worktree [--scope repo\|workspace] [--bus-dir DIR] create\|list\|show\|path\|diff\|integrate\|remove ...` | Manage persistent worker checkouts, inspect their deliveries, merge into a dedicated integration checkout, and remove clean checkouts explicitly. See [Isolated workers](#isolated-workers-with-git-worktrees). |
| `agent-init [--scope repo\|workspace] [--bus-dir DIR] [--lead] [--as PROVIDER] <name>` | Bootstrap or refresh this bus for `<name>`. Creates the resolved bus dir, registers your `CMUX_SURFACE_ID`, writes `PROTOCOL.md` and `AGENTS.md`, and purges stale entries from previous sessions. `--lead` declares `<name>` as the bus lead (strict by default — see Lead mode). `--as PROVIDER` records your provider in `.meta` so the spawn policy can classify you. |
| `agent-spawn [--scope repo\|workspace] [--bus-dir DIR] --as <claude\|codex\|opencode> [--model M] [--task TEXT [--paths "a,b"]] [--split [--dir left\|right\|up\|down]] [--title TEXT\|--no-rename] [--focus] [--say TEXT\|--no-say] <name>` | Open the worker as a **background tab** in your pane (one click away, unfocused), register `<name>` on **this** bus, and launch the chosen agent CLI in it. `--split` lays it out as a pane split instead. The new surface runs `agent-init` in its shell *before* the CLI starts (deterministic registration) and inherits your `CMUX_WORKSPACE_ID` so it lands on the same bus. The tab is renamed `"<model> - <provider>"` (`--title` / `--no-rename`). `--task` seeds a first handoff; default models come from the registry (`agent-providers`); `--model default` uses the CLI's own default. opencode's model is applied via `OPENCODE_CONFIG_CONTENT` (its TUI has no `--model` flag). Workers launch in **auto-accept** by default (claude `--permission-mode acceptEdits`; codex `--ask-for-approval never` plus a scoped profile for the bus directory and cmux Unix socket) so a delegated worker can act within its workspace without prompting a human — sandboxed, not a full bypass; `--interactive`/`--no-auto` keeps normal prompting and `--yolo` opts into full bypass. Enforced by the spawn policy. |
| `agent-dismiss [--scope repo\|workspace] [--bus-dir DIR] [--keep-pane] [--force] (<name>\|--all-spawned\|--done)` | The inverse of `agent-spawn`: close a worker's cmux pane and remove it from the registry (and its `.meta`). `--all-spawned` dismisses every lead-spawned worker; `--done` dismisses spawned workers with no open inbound thread. `--keep-pane` deregisters only; `--force` is required to dismiss yourself or the lead (dismissing the lead clears the lead pointer). |
| `agent-fleet [--scope repo\|workspace] [--bus-dir DIR] [--split [--dir DIR]] [--no-say] <name=provider[:model]> ...` | Spawn a whole team in one shot — one `agent-spawn` per spec (`fixer=codex`, `b=opencode:opencode-go/qwen3.7-max`). Workers open as background tabs by default (`--split` for panes). Validates all specs before spawning so a typo can't leave a half-built team. |
| `agent-providers [list\|init\|path\|get <provider> <field>] [--json] [--force]` | Inspect and scaffold the provider registry used by `agent-spawn` / `agent-fleet`. Built-in defaults (claude/codex/opencode) are deep-merged with a config at `$AGENT_BUS_PROVIDERS_FILE` or `${XDG_CONFIG_HOME:-~/.config}/cmux-bus/providers.json`; the config survives `./install.sh`. `init` writes the defaults to edit; `get` reads one field for scripts. |
| `agent-send [--scope repo\|workspace] [--bus-dir DIR] <to> <type> [flags] <body>` | Append event(s) and signal recipient(s). Types: `ask`, `handoff`, `done`, `block`, `ack`. Flags: `--ref ID`, `--paths "p1,p2"`, `--status STATUS`, `--ttl SEC`, `--ack-by SEC`. A `handoff` is stamped with a lease (`created_at`, `ttl` default 300s, `ack_by` default 45s) the watchdog uses to time it out. For `ask`, `<to>` may be `all` or comma-separated names (`claude,deepseek`); this fans out into one thread per peer. Refuses unknown refs and stale recipients. |
| `agent-inbox [--scope repo\|workspace] [--bus-dir DIR] [--json] [--no-stale\|--only-stale] [--no-stuck\|--only-stuck] [--stuck-after MIN]` | List open threads addressed to you, grouped by thread root. Threads whose sender is no longer registered appear with `[stale]`. Threads whose last event is `in_progress` and older than the stuck threshold (default 10 min, configurable via `AGENT_BUS_STUCK_AFTER_MIN` env) appear with `[stuck Xm]`. |
| `agent-roster [--scope repo\|workspace] [--bus-dir DIR] [--json]` | List the agents registered in the resolved bus and tell you, up front, which one you are (resolved from `CMUX_SURFACE_ID`). Marks your own row `(you)`, shows who is `lead`, and flags each peer `live`/`stale` by presence in `surface-health`. Read-only. |
| `agent-lead [--scope repo\|workspace] [--bus-dir DIR] [show\|set <name> [--relaxed]\|clear\|strict\|relaxed] [--json]` | Show, set, or clear the bus **lead** — the orchestrator agent that plans, delegates via `handoff`, and reviews results while the other agents execute. A lead is **strict** by default (delegates everything, executes nothing itself unless the user explicitly asks); `set --relaxed`, `relaxed`, and `strict` manage that policy. `set` requires a registered agent name. |
| `agent-policy [show\|path\|init\|check <caller> <provider>] [--user\|--repo] [--json] [--force]` | Inspect and scaffold the **spawn call policy** — who may create which provider via `agent-spawn` / `agent-fleet`. Built-in `open` is deep-merged with a per-user file and a per-repo file (`<git-root>/.cmux-bus/policy.json`, repo wins). Modes: `open`, `lead-only`, `matrix` (rules by provider / `lead` / `default`). `check` tests a rule; `init` scaffolds a starter. |
| `agent-lead-guard [install\|uninstall\|status] [--user\|--project]` | Claude Code hook that turns the **strict lead** convention into real enforcement. When the current pane is the strict lead, it `deny`s native `Task`/`Agent` sub-agents (use `agent-spawn` instead), `ask`s before `Edit`/`Write`/`NotebookEdit` and non-coordination `Bash` (approve only on an explicit user instruction), and injects a role reminder at `SessionStart`/`UserPromptSubmit`. Fail-open: any other session (no bus, not the lead, or `relaxed`) is untouched. `install` merges into `settings.json` (idempotent, backed up); opt-in. |
| `agent-done [--scope repo\|workspace] [--bus-dir DIR] <id> [body]` | Close a thread by appending a `done` event referencing `<id>`. |
| `agent-cancel [--scope repo\|workspace] [--bus-dir DIR] <id> [--force] [reason]` | Drop a thread by appending a `block` event to `user` with `status: blocked`. Refuses if the thread is already done/blocked unless `--force`. |
| `agent-resume [--scope repo\|workspace] [--bus-dir DIR] <id> [--force] [body]` | Re-open a stuck/crashed thread by appending a fresh `handoff` to its **original recipient**. Default body: `RESUME: <previous>`. Refuses if the thread is already done/blocked unless `--force`. |
| `agent-watchdog [--scope repo\|workspace] [--bus-dir DIR] scan\|daemon [--interval SEC]` | The independent timer that keeps a lead from blocking forever on a worker. `scan` runs one pass: for each open `handoff` whose worker pane died or whose `ack_by`/`ttl` lease expired, it appends a `timeout` event (`status=blocked`) to the delegator and signals its pane — closing the thread, releasing its claims, and unblocking any `agent-wait`. Idempotent and batched (one wake per delegator per pass). `daemon` loops `scan` every `--interval` seconds (default 30). |
| `agent-recover [--scope repo\|workspace] [--bus-dir DIR] [--max-retries N] [--dry-run] <id>` | Advance the bounded recovery cascade for a timed-out handoff: **retry** the same worker (first attempt, if alive) → **reassign** to another live peer → **escalate** to the user with a `block`. Capped at `--max-retries` (default 2) so it never loops; the next action is derived from the thread's handoff count, so re-running advances it. Each retry/reassign is a fresh leased handoff. |
| `agent-doctor [--scope repo\|workspace] [--bus-dir DIR]` | Validate the resolved bus and registry without mutating anything. Reports malformed JSONL, schema errors, duplicate ids, orphan refs, and open/stale/stuck thread counts. |
| `agent-repair [--scope repo\|workspace] [--bus-dir DIR] [--dry-run]` | Repair the resolved `bus.jsonl` when old malformed records contain raw newlines. Dry-run reports what would change; write mode creates a timestamped backup before replacing the bus. |
| `agent-guard [--scope repo\|workspace] [--bus-dir DIR] check [--json] [--staged] [--agent NAME\|--all] [PATH...]` | Detect files that overlap `paths_claimed` by open threads. By default it ignores claims owned by the current registered surface; use `--agent NAME` outside cmux or `--all` to include every claim. `--staged` checks staged git paths for pre-commit usage. |
| `agent-guard [--scope repo\|workspace] [--bus-dir DIR] install [--force]` | Install a git pre-commit hook that runs `agent-guard check --staged` and blocks commits touching files claimed by another open thread. |
| `agent-rpc [--scope repo\|workspace] [--bus-dir DIR] [--timeout SEC] [--interval SEC] [--status done\|blocked\|final] [--json] <agent> <body...>` | Send one `ask` to a single agent, wait for the thread to finish, and print the final body. Use `--json` to print the final event object. A blocked final event is printed and exits non-zero. |
| `agent-playbook [--scope repo\|workspace] [--bus-dir DIR] run <name-or-path> [KEY=VALUE...]` | Run a JSON workflow from `<bus-dir>/playbooks/<name>.json` or an explicit path. Supports `send`, `wait`, `rpc`, and `print` steps with `{{variable}}` interpolation. |
| `agent-synthesize [--scope repo\|workspace] [--bus-dir DIR] [--agent NAME] [--timeout SEC] [--interval SEC] [--json] <id...>` | Wait for multiple threads to finish, bundle their final replies, and ask the synthesis agent (default `claude`) for consensus, disagreements, and a recommendation. |
| `agent-thread [--scope repo\|workspace] [--bus-dir DIR] [--json] <id>` | Show the full event history for any event id in a thread. |
| `agent-watch [--scope repo\|workspace] [--bus-dir DIR] [--once] [--me] [--full] [--no-color] [--clear] [--lines N] [--interval SEC]` | Watch bus events as they are appended. Use `--once` for a snapshot, `--me` to show only events involving the current registered surface, `--full` to avoid body truncation, and `--clear` to truncate the resolved `bus.jsonl` before watching. |
| `agent-notify [--scope repo\|workspace] [--bus-dir DIR] <enable\|disable\|ensure\|status\|once\|run> [--interval SEC] [--label TEXT] [--replay]` | Automatic read-only bridge from bus events to native cmux pop-ups. `agent-init` enables a persistent per-bus LaunchAgent by default; `disable` is a durable opt-out and `enable` restores it. It notifies `ask`, `handoff`, `done`, `block`, and `timeout` events while acknowledgements stay silent. The recipient surface is targeted so clicking opens the relevant agent. `start`/`stop` remain aliases for `enable`/`disable`. |
| `agent-wait [--scope repo\|workspace] [--bus-dir DIR] [--timeout SEC] [--interval SEC] [--status done\|blocked\|final] <id>` | Wait for a thread to reach `done`, `blocked`, or either final state. Prints the final event as JSON. A watchdog `timeout` event is terminal for any target and exits **3** (distinct from a real done/blocked); the wait's own deadline also exits 3; unknown id exits 1. |

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

## Isolated workers with Git worktrees

Use `--worktree` to give each coding worker a **separate directory, branch and
Git index**, while keeping the same cmux message bus. Git is required for this
mode, and the source repository must have at least one commit.

```sh
agent-spawn --as codex --worktree --task "Implement the API" --paths "src/api/*" api
agent-spawn --as claude --worktree --task "Implement the UI" --paths "src/ui/*" ui

# Or prepare a whole team at one immutable starting commit:
agent-fleet --worktree --base HEAD api=codex ui=claude reviewer=codex
```

`--base REF` defaults to committed `HEAD`. Local edits, untracked files, `.env`,
installed dependencies and ignored artifacts are **not copied**. Prepare each
checkout's environment as needed; assign separate ports/databases when the
project uses shared services. Worktrees isolate working files, not OS processes
or external services. They still share Git objects, refs and repository config.

The bootstrap changes directory before launching the provider, exports the
absolute bus path (including in repo scope), and uses `agent-init --no-files` so
runtime setup does not modify tracked `AGENTS.md` or `.gitignore` files. Existing
project instructions remain present; the onboarding/handoff points to the bus
protocol. Auto-accept Codex workers also get access to the shared Git metadata
needed for commits. `--worktree` remains opt-in; ordinary spawns are unchanged.

Records live in `<bus-dir>/worktrees/records/<name>.json`, independently of the
surface registry, and checkouts in `<bus-dir>/worktrees/checkouts/<name>`.
Each record stores the repository, branch, base commit and checkout path.
`agent-roster` shows the active workers' branches and paths; `agent-worktree list`
also shows retained worktrees after their agents disappear.

```sh
agent-worktree list --json
agent-worktree show api
agent-worktree diff api              # tracked changes since the starting commit
cd "$(agent-worktree path api)"
```

Relative `--paths` on a handoff to a managed worker are resolved against **that
worker's checkout**, using the additive `claims_cwd` event field. `cwd` keeps its
original meaning (sender directory). Thus two workers can both claim `src/api.ts`
in their own worktrees; reservations still protect agents sharing a checkout.
Managed handoffs reject absolute paths and `..` components in claims.

### Deliver, integrate, and clean up

Workers commit their contribution on their own branch, run the relevant checks,
then call `agent-done`. Its event includes the worktree, commit and dirty state;
`done` means the worker has delivered, **not** that the code has been merged.

```sh
# Once the worker has finished its handoff:
agent-dismiss api                   # closes the pane; retains all work
agent-worktree integrate api --check './tests/run.sh'
agent-dismiss ui
agent-worktree integrate ui --check './tests/run.sh'
agent-worktree show ui --json        # .integration.path / branch / commit
agent-worktree remove api
```

Integration requires a dismissed worker, no open handoff and a clean worker
checkout. It serializes integrations per Git repository and merges committed
changes into a **dedicated integration worktree/branch per repository and bus**.
The original checkout and branch are untouched. `--check` runs in that combined
checkout **before** the merge commit; omitting it performs no automatic tests.
Check commands must not modify tracked files or the index.

A conflict or failed check exits non-zero and leaves the pending merge in the
integration checkout for inspection. Resolve and commit there, or run
`git -C <integration-path> merge --abort`, then retry. After a manual resolution,
rerunning `integrate` records the integration and can rerun checks. Review and
promote the resulting integration branch with your normal Git/PR workflow;
there is no automatic merge into `main`, push or PR creation.

`remove` refuses registered workers, open handoffs, dirty/ignored files and
commits absent from the integration checkout. `remove --keep-branch` permits
removing a clean, unmerged checkout while retaining its commits on the branch.
**Branches are always retained**, and there is no forced deletion. Recreating a
removed name archives its old record under `worktrees/history/`.

### Resume an interrupted worker

```sh
agent-spawn --as codex --worktree --no-say api
agent-resume --force <thread-id>
```

Reusing the same name on the same bus reuses its branch and checkout, including
uncommitted work. A live name, another repository or a conflicting explicit base
is rejected. If the old agent is still registered/live, dismiss it first.
`agent-recover` can retry the same live worker, but escalates with the retained
path instead of silently transferring an isolated worker's task to another
checkout. The fresh handoff gets a new watchdog lease.

## Native cmux pop-ups (automatic)

`agent-init` automatically installs and starts one persistent notifier for the
current bus. It survives terminal, cmux, and login restarts through a macOS
LaunchAgent. No per-agent setup is needed.

Notifications are enabled by default. Opt out for one bus with:

```sh
agent-notify disable
```

Restore the default with `agent-notify enable`; inspect it with
`agent-notify status`. Use `--label "Recherche IA"` with `enable` to override
the workspace label.

Typical pop-ups are “Claude a confié une tâche à Codex”, “Codex a terminé son
travail pour Claude”, or “Codex est bloqué”. The notifier only reads
`bus.jsonl`; it stores its PID, cursor, and opt-out state under the runtime bus
directory and does not change the protocol or append events.

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

## Lead mode

By default the bus is peer-to-peer. You can instead declare one agent as the
**lead** — the orchestrator that thinks, plans, and reviews, while cheaper
models execute. The typical setup puts the strongest (most expensive) model
in the lead pane:

```sh
# lead pane (e.g. Claude on a frontier model)
agent-init claude --lead

# worker panes
agent-init codex
agent-init deepseek
```

### The lead builds its own team

You don't have to open and initialize each worker pane by hand. Once a lead is
running, it can recruit workers itself with `agent-spawn`: open a fresh split,
register the worker on the same bus, and launch its CLI — then delegate as
usual. So you only ever start the lead and tell it what you want:

```sh
# you, to the lead pane: "ask codex to bisect the flaky test, then clean up"

# the lead does, on its own — spawn and delegate in one step:
agent-spawn fixer --as codex \
  --task "Bisect the flaky test in tests/, propose a fix, reply done with the commit" \
  --paths "tests/**"
# ... lead reviews the `done` it gets back ...
agent-dismiss fixer                                # close the pane, shrink the team
```

`agent-spawn` registers the worker deterministically (it runs `agent-init` in
the new pane's shell before the CLI launches). With `--task` it seeds the first
`handoff` on the bus the moment the worker registers; without it, delegate later
with `agent-send`. Pick the provider and model per task (`--as
claude|codex|opencode`, `--model`); defaults come from the registry
(`agent-providers`). Stand up a standard squad in one command:

```sh
agent-fleet reviewer=claude tester=codex bencher=codex   # three workers at once
agent-dismiss --done                                     # later: drop the finished ones
```

The lead decomposes work and delegates each task as a `handoff` with explicit
acceptance criteria and `paths_claimed`, then reviews every `done` against
those criteria. Rework is requested with a new `handoff --ref` on the same
thread, which reopens it (effective state is the last event in the chain).
Workers `ack`, execute, and reply `done` with verifiable evidence; they `ask`
the lead before self-assigning new non-trivial work.

The role is stored as a top-level `"lead"` key in the resolved `agents.json`
and is announced by `agent-roster` and `agent-lead`, so every agent learns
its role at session start. Like path ownership, lead mode is a declared
convention, not an enforced lock. Manage it anytime:

```sh
agent-lead              # show the current lead (and whether it's you)
agent-lead set codex    # promote a registered agent
agent-lead clear        # back to peer-to-peer mode
```

`agent-init` keeps the pointer coherent: it follows a same-surface rename and
clears the lead when its surface disappears. The user always outranks the
lead — a direct user instruction to a worker wins over the lead's plan.

### Lead execution policy (strict by default)

A lead is **strict** unless told otherwise: it plans and delegates and does
**not** edit, run, or execute anything itself — the only exception is an
explicit user instruction. This is a declared convention (like path ownership),
surfaced to the lead by `agent-roster` and `agent-lead` so it reads its stance
at session start.

```sh
agent-lead set claude --lead    # strict by default
agent-lead relaxed              # let the lead execute directly when it judges fit
agent-lead strict               # back to delegate-only
agent-lead                      # show lead + policy
```

The state lives as an optional `lead_policy` key in `agents.json` (absent ⇒
strict). `agent-lead clear` removes both the lead and its policy.

By default this is a *declared* convention. To make it **enforced**, install the
Claude Code hook:

```sh
agent-lead-guard install        # opt-in; merges into settings.json (backed up)
```

When the current pane is the strict lead, the hook:
- **denies** native `Task`/`Agent` sub-agents → you must use `agent-spawn` so
  workers land on the bus (visible, path-claimed, reviewable);
- **asks** before `Edit`/`Write`/`NotebookEdit` and non-coordination `Bash`
  (you approve only when the user explicitly told the lead to act itself);
- **allows** reads and bus/coordination commands (`agent-*`, `cmux`, `git
  status`, …) so delegation always works;
- **injects** a "you are the strict lead" reminder at session start and on each
  prompt, so the role survives context compaction.

It is fail-open: any session that is not a strict lead (no bus, not the lead, or
`relaxed`) is left completely untouched. `agent-lead-guard uninstall` removes it.

### Spawn call policy (who may create whom)

Independently, you can restrict **which agent may create which provider** via
`agent-spawn` / `agent-fleet`. The policy resolves from a built-in default
(`open`) deep-merged with a per-user file
(`${XDG_CONFIG_HOME:-~/.config}/cmux-bus/policy.json`) and a per-repo file
(`<git-root>/.cmux-bus/policy.json`, repo wins). Modes:

- `open` (default) — anyone may spawn anyone.
- `lead-only` — only the lead may spawn.
- `matrix` — rules keyed by the caller's **provider** (or the special `lead`
  role, or `default`), each listing the providers it may spawn (`*` = any).

```jsonc
// .cmux-bus/policy.json — committable, per-repo
{ "spawn": { "mode": "matrix", "rules": {
    "lead":   ["*"],
    "claude": ["codex", "opencode"],
    "codex":  []
} } }
```

The caller's provider comes from `.meta.provider` (set by `agent-spawn`, or
self-declared with `agent-init --as <provider>`). `agent-spawn`/`agent-fleet`
**enforce** this and refuse a forbidden creation; it gates creation only, not
`handoff` delegation between existing agents.

```sh
agent-policy init --repo                  # scaffold a starter repo policy
agent-policy show                         # resolved mode + rules + sources
agent-policy check claude codex           # test a rule (allow / deny)
```

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

- No autonomous task scheduler (workflows and worktree operations are explicit)
- Not a tmux thing (uses cmux's native API; tmux users have plenty of
  better-fit projects)
- No central broker or HTTP service (watchdog and notification helpers run locally)
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

## Live workspace agent counts

`agent-presence enable` installs an independent, read-only sidebar showing agents
working, awaiting a response, and idle. It also works with the bus disabled.
See [PRESENCE.md](PRESENCE.md) for setup, lifecycle semantics and limitations.
