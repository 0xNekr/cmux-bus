<!-- agent-bus:start v1 -->
## Multi-agent bus (cmux)

This workspace runs a multi-agent coordination protocol. Peer agents (typically
Claude and Codex) work in adjacent cmux panes and communicate via an event log
at `.agents/bus.jsonl`.

**At session start:**
1. Read `.agents/PROTOCOL.md` once — it defines the schema, types, inbox
   routine, path-ownership rule, and disagreement escalation.
2. Run `agent-inbox` to see open threads addressed to you. Process them before
   taking new work.

**To send or hand off:** `agent-send <to> <type> [--ref ID] [--paths "p1,p2"]
<body>`. Types: `ask`, `handoff`, `done`, `block`, `ack`.
**To close a thread:** `agent-done <id> [body]`.
**Never edit a path another agent has claimed in an open thread.**

Peers and surfaces are listed in `.agents/agents.json`.
<!-- agent-bus:end v1 -->
