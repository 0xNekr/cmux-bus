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
   path-ownership rule, and disagreement escalation.
2. Run `agent-inbox` to see open threads addressed to you. Process them before
   taking new work.

**To send or hand off:** `agent-send <to> <type> [--ref ID] [--paths "p1,p2"]
<body>`. Types: `ask`, `handoff`, `done`, `block`, `ack`.
**To close a thread:** `agent-done <id> [body]`.
**To override scope for one command:** add `--scope repo` or `--scope workspace`.
**Never edit a path another agent has claimed in an open thread.**

Peers and surfaces are listed in the resolved bus `agents.json`.
Do not read `.agents/agents.json` or `.agents/bus.jsonl` by hand; in workspace
scope `.agents/` may only be a stub.
<!-- agent-bus:end v1 -->
