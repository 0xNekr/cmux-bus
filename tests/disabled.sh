#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'for pid in ${waiter:-} ${watchdog:-} ${notifier:-}; do kill "$pid" 2>/dev/null || true; done; rm -rf "$scratch"' EXIT
export HOME="$scratch/home" XDG_STATE_HOME="$scratch/state"
export AGENT_BUS_NOTIFY_AUTO=0 AGENT_BUS_NO_WATCHDOG=1
unset AGENT_BUS_DIR AGENT_BUS_SCOPE
export CMUX_WORKSPACE_ID=independent CMUX_SURFACE_ID=s1
mkdir -p "$HOME" "$scratch/bin" "$scratch/repo"
export PATH="$scratch/bin:$repo_root/bin:$PATH"
cat > "$scratch/bin/cmux" <<'CMUX'
#!/usr/bin/env bash
case "$1" in
    identify) echo '{"caller":{"workspace_id":"independent"}}';;
    --id-format) printf 'surface:1 s1 type=terminal\nsurface:2 s2 type=terminal\n';;
    *) echo "$*" >> "$HOME/cmux.log";;
esac
CMUX
cat > "$scratch/bin/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
[ "$1" != print ]
LAUNCHCTL
chmod +x "$scratch/bin/cmux" "$scratch/bin/launchctl"
cd "$scratch/repo"
git init -q
fail() { echo "not ok - $*" >&2; exit 1; }
blocked() {
    local code=0
    "$@" > "$scratch/output" 2>&1 || code=$?
    [ "$code" -eq 4 ] || { cat "$scratch/output"; fail "expected disabled exit 4 ($code): $*"; }
    grep -q 'bus disabled' "$scratch/output" || fail "missing independent-mode guidance"
}
[ "$(agent-bus status)" = enabled ] || fail status
[ ! -e "$XDG_STATE_HOME" ] || fail 'status must be read-only'
AGENT_BUS_DIR="$scratch/ignored" AGENT_BUS_SCOPE=repo agent-bus disable
agent-bus disable
[ "$(agent-bus status)" = disabled ] || fail status
if agent-bus status --quiet; then fail 'quiet disabled'; fi
for surface in s1 s2 s3 s4; do
    CMUX_SURFACE_ID="$surface" blocked agent-init --no-files "agent${surface}"
done
blocked agent-init --scope repo --no-files local
blocked agent-init --bus-dir "$scratch/override" --no-files explicit
[ ! -e "$scratch/override" ] && [ ! -e AGENTS.md ] && [ ! -e .agents ] || fail 'init side effects'
(cd "$scratch"; blocked agent-init --no-files otherdir)
env -u CMUX_WORKSPACE_ID agent-bus status | grep -qx disabled || fail 'caller resolution'
CMUX_WORKSPACE_ID=other agent-init --no-files peer >/dev/null
[ ! -e "$XDG_STATE_HOME/cmux-bus/workspaces/other/disabled" ] || fail 'workspace isolation'
for command in agent-inbox agent-roster agent-lead agent-doctor agent-spawn; do
    # Each command has different required arguments; init/spawn are covered separately.
    case "$command" in agent-spawn) blocked "$command" worker --as codex;; *) blocked "$command";; esac
done
agent-bus enable
agent-bus status --quiet
agent-init --no-files --lead lead >/dev/null
CMUX_SURFACE_ID=s2 agent-init --no-files worker >/dev/null
agent-send worker handoff 'keep this work' >/dev/null
bus="$XDG_STATE_HOME/cmux-bus/workspaces/independent"
id="$(tail -n1 "$bus/bus.jsonl" | jq -r .id)"
cp "$bus/agents.json" "$scratch/registry.before"
cp "$bus/bus.jsonl" "$scratch/events.before"
# Wait must notice disabling even if started before the switch.
agent-wait --interval 0.1 --timeout 10 "$id" > "$scratch/wait.log" 2>&1 &
waiter=$!
agent-watchdog daemon --interval 1 > "$scratch/watchdog.log" 2>&1 &
watchdog=$!
agent-notify run --interval 0.1 > "$scratch/notify.log" 2>&1 &
notifier=$!
for attempt in {1..100}; do
    [ ! -f "$bus/watchdog.pid" ] || [ ! -f "$bus/notifier/pid" ] || break
    sleep 0.05
done
[ -f "$bus/watchdog.pid" ] && [ -f "$bus/notifier/pid" ] || fail 'services did not start'
agent-bus disable
wait "$watchdog" || true
wait "$notifier" || true
[ ! -f "$bus/watchdog.pid" ] && [ ! -f "$bus/notifier/pid" ] || fail 'services not stopped'
code=0
wait "$waiter" || code=$?
[ "$code" -eq 4 ] || { cat "$scratch/wait.log"; fail 'active wait did not stop'; }
blocked agent-send worker ask hello
blocked agent-watchdog scan
blocked agent-notify ensure
blocked agent-notify enable
blocked env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID agent-inbox --bus-dir "$bus"
# Strict lead hook must not deny ordinary tools after disabling.
result="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"x"}}' | agent-lead-guard)"
[ -z "$result" ] || fail 'strict lead hook still applies'
agent-guard check --paths x >/dev/null
cmp "$bus/agents.json" "$scratch/registry.before" || fail 'registry changed'
cmp "$bus/bus.jsonl" "$scratch/events.before" || fail 'history changed'
# Independent notification preference survives both modes.
mkdir -p "$bus/notifier"
touch "$bus/notifier/disabled"
agent-bus disable
agent-bus enable
[ -f "$bus/notifier/disabled" ] || fail 'notification opt-out lost'
agent-init --no-files lead >/dev/null
agent-send worker ask 'coordination restored' >/dev/null
# No workspace must fail rather than affect a focused/default workspace.
cat > "$scratch/bin/cmux" <<'CMUX'
#!/usr/bin/env bash
echo '{}'
CMUX
if env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID agent-bus disable > /dev/null 2>&1; then fail 'missing workspace accepted'; fi
if agent-bus disable --scope repo > /dev/null 2>&1; then fail 'scope override accepted'; fi
echo 'ok - workspace disable: four panes, overrides, isolation, hooks, services, history and re-enable'
