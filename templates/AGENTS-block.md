<!-- agent-bus:start v1 -->
## Multi-agent bus (cmux)

This workspace runs a multi-agent coordination protocol. Peer agents (typically
Claude and Codex) work in adjacent cmux panes and communicate via an event log
resolved by the `agent-*` commands. By default the bus is scoped to the
current cmux workspace, not the current folder. Use `AGENT_BUS_SCOPE=repo` or
`--scope repo` only when you intentionally want a folder-local `.agents/` bus.

**At session start:**
1. Treat `agent-inbox` as the source of truth for the current bus. The protocol
   copied by `agent-init` defines the schema, types, inbox routine,
   path-ownership rule, lead mode, and disagreement escalation.
2. Run `agent-roster` to learn who you are and whether a **lead** is set.
3. Run `agent-inbox` to see open threads addressed to you. Process them before
   taking new work.

**If a lead is set** (see `agent-lead`): the lead plans, delegates via
`handoff` with acceptance criteria and `paths_claimed`, and reviews every
`done`. By default the lead is **strict** — it does NOT edit/run/execute
anything itself, only delegates, unless the user explicitly says otherwise
(`agent-lead relaxed` opts out). Workers `ack`, execute, and reply `done` with
verifiable evidence; they `ask` the lead before self-assigning new non-trivial
work. On worker/lead disagreement, one round-trip, then the lead decides. The
user always outranks the lead. Who may spawn whom is governed by the spawn call
policy (`agent-policy`; modes open / lead-only / matrix). The lead can build its own team:
`agent-spawn <name> --as <claude|codex|opencode> [--model M] [--task "..."]`
opens a new pane, registers the worker on this bus, launches its CLI, and
optionally hands it a first task; `agent-fleet a=codex b=claude ...` spawns a
whole squad; `agent-dismiss <name>` (or `--done` / `--all-spawned`) tears them
down. Provider defaults live in `agent-providers`.

**To send or hand off:** `agent-send <to> <type> [--ref ID] [--paths "p1,p2"]
<body>`. Types: `ask`, `handoff`, `done`, `block`, `ack`.
**To close a thread:** `agent-done <id> [body]`.
**To override scope for one command:** add `--scope repo` or `--scope workspace`.
**Never edit a path another agent has claimed in an open thread.**

Peers and surfaces are listed in the resolved bus `agents.json`.
Do not read `.agents/agents.json` or `.agents/bus.jsonl` by hand; in workspace
scope `.agents/` may only be a stub.
<!-- agent-bus:end v1 -->
