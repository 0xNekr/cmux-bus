#!/usr/bin/env bash
# cmux-bus installer — symlinks bin/agent-* into ~/.local/bin and (if Claude
# Code is present) installs the agent protocol rule.

set -euo pipefail

want_guard=0
for arg in "$@"; do
    case "$arg" in
        --guard) want_guard=1;;
        -h|--help)
            echo "usage: ./install.sh [--guard]"
            echo "  --guard   also enable the strict-lead enforcement hook (agent-lead-guard install)"
            exit 0
            ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src_bin="$repo_root/bin"
tools=(agent-init agent-spawn agent-dismiss agent-fleet agent-providers agent-policy agent-lead-guard agent-send agent-inbox agent-roster agent-lead agent-done agent-cancel agent-resume agent-doctor agent-repair agent-guard agent-rpc agent-playbook agent-synthesize agent-thread agent-watch agent-wait agent-update)

missing=()
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v cmux >/dev/null 2>&1 || missing+=("cmux")
if [ ${#missing[@]} -gt 0 ]; then
    echo "error: missing required commands: ${missing[*]}" >&2
    echo "  install jq: https://jqlang.github.io/jq/" >&2
    echo "  install cmux: https://cmux.com" >&2
    exit 1
fi

target_dir="$HOME/.local/bin"
mkdir -p "$target_dir"

case ":$PATH:" in
    *":$target_dir:"*) ;;
    *) echo "warning: $target_dir is not in your PATH" >&2 ;;
esac

for tool in "${tools[@]}"; do
    src="$src_bin/$tool"
    if [ ! -f "$src" ]; then
        echo "error: missing $src" >&2
        exit 1
    fi
    chmod +x "$src"
done

linked=()
for tool in "${tools[@]}"; do
    src="$src_bin/$tool"
    dst="$target_dir/$tool"
    ln -sfn "$src" "$dst"
    linked+=("$dst -> $src")
done

echo "installed:"
for line in "${linked[@]}"; do
    echo "  $line"
done

claude_rules="$HOME/.claude/rules"
if [ -d "$claude_rules" ]; then
    rule_dst="$claude_rules/agents-protocol.md"
    cat > "$rule_dst" <<'RULE'
# Multi-Agent Bus (cmux)

If `agent-inbox` finds a registered surface for you, you are part of a
multi-agent setup with peer agents (typically Codex) running in adjacent cmux
panes. By default the bus is scoped to the current cmux workspace; use
`AGENT_BUS_SCOPE=repo` or `--scope repo` only for a folder-local `.agents/`
bus.

The same folder can be open in several cmux workspaces at once (e.g. Linear,
Infra, Breeve on one repo); each workspace gets its **own separate bus**.
Resolution is bound to your pane's `CMUX_WORKSPACE_ID`, so you always act on
your own workspace's bus — agents never collide on a shared registry.

In workspace scope, `.agents/` may only be a stub. Do not read
`.agents/agents.json` or `.agents/bus.jsonl` by hand as the source of truth;
use the `agent-*` commands.

## Required behavior

1. **At session start in such a workspace**, treat `agent-inbox` as the
   source of truth for open work. The protocol copied by `agent-init` defines
   the message schema, types, status semantics, inbox routine, path-ownership
   rule, lead mode, and the disagreement escalation rule.
2. **Check your role** with `agent-roster` (or `agent-lead`): the bus may
   declare a lead agent. See "Lead mode" below.
3. **Before taking any new task**, run `agent-inbox` to see open threads
   addressed to you. Process them in chronological order.
4. **To send a message or hand off work**, use `agent-send <to> <type>
   [--ref ID] [--paths "p1,p2"] <body>`. Always claim `paths_claimed` for
   handoffs that involve file edits.
5. **To close a thread**, use `agent-done <id> [body]`.
6. **Never edit a path** that another agent has claimed in an open thread.
7. **On disagreement**, after two unresolved round-trips, escalate via a
   `block` event to `to=user` with a clear summary, each agent's
   recommendation, and concrete options.
8. **If a peer is missing or stale**, ask them to run `agent-init <name>` in
   their current pane. Do not use `cmux send` as a fallback for bus messages.

## Lead mode

The bus may declare one lead agent (`agent-init <name> --lead`, or
`agent-lead set <name>`). The intent is cost-tiering: the strongest model
plans and reviews, cheaper peers execute.

- **If you are the lead**: by default you are in **STRICT** mode — you plan,
  decompose, and delegate, and you do **NOT** edit, run, or execute anything
  yourself. The only exception is an explicit user instruction to do it
  yourself. Delegate every task via `handoff` with explicit acceptance
  criteria and `paths_claimed`; review every `done` against those criteria;
  request rework with a new `handoff --ref` on the same thread. Reading is
  always fine. Never give two workers overlapping path claims. Check your
  policy with `agent-roster` / `agent-lead` — a `relaxed` lead (set via
  `agent-lead relaxed`) may execute work directly when it judges fit.
- **Who may spawn whom** is governed by the spawn call policy
  (`agent-policy`). If `agent-spawn`/`agent-fleet` refuses, the policy
  forbids that caller from creating that provider — surface it to the user
  rather than working around it.
- **Strict enforcement** may be active via a Claude Code hook
  (`agent-lead-guard`): if a tool call to edit/run/spawn is denied or
  prompts for approval, that is the strict-lead policy — delegate via the
  bus instead of retrying, unless the user explicitly approves.
- **Building your own team**: you can recruit workers yourself, without the
  user opening panes. `agent-spawn <name> --as <claude|codex|opencode>
  [--model M] [--task "..." --paths "..."]` opens the worker as a background
  tab in your pane (unfocused; `--split` for a pane instead), registers
  `<name>` on this same bus, launches that provider's CLI, and
  (with `--task`) hands it a first `handoff`. Pick the provider/model that
  fits the task (codex for CLI diagnostics, claude for design). Without
  `--task`, delegate afterward with `agent-send`. Spin up a whole squad at
  once with `agent-fleet name1=codex name2=claude ...`. Provider launch
  commands and default models come from the registry — inspect or customize
  them with `agent-providers list` / `agent-providers init`.
- **Tearing it down**: `agent-dismiss <name>` closes a worker's pane and
  deregisters it; `agent-dismiss --done` sweeps workers whose threads are all
  closed; `agent-dismiss --all-spawned` removes the whole spawned team.
  `agent-roster` shows each worker's provider/model under VIA. So the user
  need only start you and say e.g. "ask codex to ..." — you spawn the codex
  worker, delegate, review, and dismiss it when finished.
- **If you are a worker**: process the lead's handoffs first (`ack` →
  execute → `done` with verifiable evidence: commands run, test output,
  commit ids). `ask` the lead before self-assigning new non-trivial work
  or when acceptance criteria are ambiguous.
- **Arbitration**: one worker↔lead round-trip, then the lead decides.
  The user always outranks the lead; if the user instructs you directly,
  follow the user and tell the lead via an `ask`.

## Setup in a fresh workspace

If the user wants the multi-agent bus, run `agent-init <your_agent_name>`.
Each agent runs `agent-init` once with its own name; the script registers your
`CMUX_SURFACE_ID` in the resolved bus `agents.json` so peers can signal you.
To bootstrap a managed fleet, the orchestrator pane runs
`agent-init <name> --lead` and each worker pane runs `agent-init <name>`.
RULE
    echo "installed Claude rule: $rule_dst"
fi

if [ "$want_guard" -eq 1 ]; then
    echo ""
    "$src_bin/agent-lead-guard" install || echo "warning: agent-lead-guard install failed" >&2
fi

echo ""
echo "next steps:"
echo "  1. open two cmux panes in a workspace"
echo "  2. in each pane: agent-init <name>   (e.g. claude / codex)"
echo "  3. agent-send <peer> handoff \"...\""
if [ "$want_guard" -eq 0 ]; then
    echo ""
    echo "optional: enforce the STRICT lead with Claude Code hooks (opt-in):"
    echo "  ./install.sh --guard            # or: agent-lead-guard install"
    echo "  agent-lead-guard uninstall      # remove it"
fi
