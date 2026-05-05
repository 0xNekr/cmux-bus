#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

pass_count=0

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    pass_count=$((pass_count + 1))
    echo "ok $pass_count - $1"
}

make_fake_cmux() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/cmux" <<'CMUX'
#!/usr/bin/env bash
if [ "$1" = "--id-format" ] && [ "${2:-}" = "both" ] && [ "${3:-}" = "surface-health" ]; then
    cat <<'OUT'
surface:1 s1 type=terminal in_window=true
surface:2 s2 type=terminal in_window=true
OUT
    exit 0
fi
if [ "$1" = "send" ] || [ "$1" = "send-key" ]; then
    if [ -n "${CMUX_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$CMUX_LOG"
    fi
    exit 0
fi
exit 0
CMUX
    chmod +x "$dir/cmux"
}

new_workspace() {
    local name="$1"
    local dir="$tmp_root/$name"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

write_agents() {
    mkdir -p .agents
    printf '%s\n' '{"agents":{"codex":"s1","claude":"s2"}}' > .agents/agents.json
    touch .agents/bus.jsonl
}

test_agent_init_syncs_protocol_and_template() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-init"
    workspace="$(new_workspace init)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" codex >/dev/null
        cmp -s .agents/PROTOCOL.md "$repo_root/PROTOCOL.md"
        cmp -s AGENTS.md "$repo_root/templates/AGENTS-block.md"
        jq -e '.agents.codex == "s1"' .agents/agents.json >/dev/null
        grep -qxF ".agents/" .gitignore
    )

    pass "agent-init syncs protocol and AGENTS template"
}

test_agent_init_via_symlink() {
    local fakebin bindir workspace
    fakebin="$tmp_root/fakebin-init-symlink"
    bindir="$tmp_root/bin"
    workspace="$(new_workspace init-symlink)"
    make_fake_cmux "$fakebin"
    mkdir -p "$bindir"
    ln -s "$repo_root/bin/agent-init" "$bindir/agent-init"

    (
        cd "$workspace"
        PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s2 "$bindir/agent-init" claude >/dev/null
        cmp -s .agents/PROTOCOL.md "$repo_root/PROTOCOL.md"
        cmp -s AGENTS.md "$repo_root/templates/AGENTS-block.md"
        jq -e '.agents.claude == "s2"' .agents/agents.json >/dev/null
    )

    pass "agent-init resolves repo files through symlink"
}

test_install_links_all_commands() {
    local fakebin home tool
    fakebin="$tmp_root/fakebin-install"
    home="$tmp_root/home-install"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    PATH="$fakebin:$PATH" HOME="$home" "$repo_root/install.sh" >/dev/null
    for tool in agent-init agent-send agent-inbox agent-done agent-cancel agent-resume; do
        [ -L "$home/.local/bin/$tool" ] || fail "$tool was not symlinked"
        [ "$(readlink "$home/.local/bin/$tool")" = "$repo_root/bin/$tool" ] || fail "$tool symlink target is wrong"
    done

    pass "install.sh links all commands"
}

test_agent_send_ref_validation() {
    local err_file workspace
    workspace="$(new_workspace ref-validation)"
    err_file="$tmp_root/ref-validation.err"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"user",to:"codex",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"root"}' > .agents/bus.jsonl
        CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user done --ref root1234 "valid ref" >/dev/null
        [ "$(jq -s length .agents/bus.jsonl)" = "2" ] || fail "valid ref did not append"
        jq -s -e '.[1].ref == "root1234"' .agents/bus.jsonl >/dev/null

        if CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user done --ref missing99 "bad ref" 2>"$err_file"; then
            fail "invalid ref unexpectedly succeeded"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "2" ] || fail "invalid ref appended to bus"
        grep -q "unknown --ref 'missing99'" "$err_file"
    )

    pass "agent-send rejects orphan refs without appending"
}

test_agent_send_peer_paths_status_and_signal() {
    local fakebin workspace cmux_log event_id
    fakebin="$tmp_root/fakebin-send-peer"
    workspace="$(new_workspace send-peer)"
    cmux_log="$tmp_root/cmux-send-peer.log"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        event_id=$(PATH="$fakebin:$PATH" CMUX_LOG="$cmux_log" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude handoff --paths "a.ts, b.ts ,c.ts" --status in_progress "peer task")
        [ -n "$event_id" ] || fail "agent-send did not print event id"
        jq -s -e '
            length == 1
            and .[0].id == $id
            and .[0].to == "claude"
            and .[0].status == "in_progress"
            and .[0].paths_claimed == ["a.ts","b.ts","c.ts"]
        ' --arg id "$event_id" .agents/bus.jsonl >/dev/null
        grep -q "send --surface s2 new handoff id=$event_id from=codex" "$cmux_log"
        grep -q "send-key --surface s2 Enter" "$cmux_log"
    )

    pass "agent-send records paths/status and signals peer"
}

test_agent_send_multiline_body() {
    local workspace
    workspace="$(new_workspace multiline)"

    (
        cd "$workspace"
        write_agents
        CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user block $'line 1\nline 2' >/dev/null
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "1" ] || fail "multiline body wrote multiple physical lines"
        jq -s -e 'length == 1 and .[0].body == "line 1\nline 2"' .agents/bus.jsonl >/dev/null
    )

    pass "agent-send stores multiline body as one JSONL event"
}

test_agent_done_smoke() {
    local fakebin workspace cmux_log done_id
    fakebin="$tmp_root/fakebin-done"
    workspace="$(new_workspace done)"
    cmux_log="$tmp_root/cmux-done.log"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"root"}' > .agents/bus.jsonl
        done_id=$(PATH="$fakebin:$PATH" CMUX_LOG="$cmux_log" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-done" root1234 "done body")
        [ -n "$done_id" ] || fail "agent-done did not print event id"
        jq -s -e '
            length == 2
            and .[1].id == $id
            and .[1].type == "done"
            and .[1].ref == "root1234"
            and .[1].to == "claude"
            and .[1].status == "done"
            and .[1].body == "done body"
        ' --arg id "$done_id" .agents/bus.jsonl >/dev/null
        grep -q "send --surface s2 new done id=$done_id from=codex" "$cmux_log"
    )

    pass "agent-done appends done event and signals originator"
}

test_concurrent_writes_stay_valid() {
    local workspace i
    workspace="$(new_workspace concurrent)"

    (
        cd "$workspace"
        write_agents
        for i in $(seq 1 25); do
            CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user block "message $i" >/dev/null &
        done
        wait
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "25" ] || fail "concurrent writes lost events"
        [ "$(jq -s length .agents/bus.jsonl)" = "25" ] || fail "concurrent writes produced invalid JSONL"
    )

    pass "concurrent agent-send writes remain valid JSONL"
}

test_agent_inbox_empty_bus() {
    local workspace output
    workspace="$(new_workspace inbox-empty)"

    (
        cd "$workspace"
        write_agents
        output=$(CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-inbox")
        [ "$output" = "agent-inbox: no open threads for codex" ] || fail "unexpected empty inbox output: $output"
    )

    pass "agent-inbox handles empty bus"
}

test_agent_cancel_and_resume_smoke() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-recovery"
    workspace="$(new_workspace recovery)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:["src/a.ts"],body:"do work"}' > .agents/bus.jsonl
        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-resume" root1234 >/dev/null
        jq -s -e 'length == 2 and .[1].type == "handoff" and .[1].to == "claude" and .[1].ref == "root1234"' .agents/bus.jsonl >/dev/null
        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-cancel" root1234 "dropping" >/dev/null
        jq -s -e 'length == 3 and .[2].type == "block" and .[2].to == "user" and .[2].status == "blocked"' .agents/bus.jsonl >/dev/null
    )

    pass "agent-resume and agent-cancel append expected recovery events"
}

test_agent_inbox_stale_and_stuck() {
    local workspace old_ts
    workspace="$(new_workspace inbox)"
    old_ts="$(date -u -v-20M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '20 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")"

    (
        cd "$workspace"
        mkdir -p .agents
        printf '%s\n' '{"agents":{"codex":"s1"}}' > .agents/agents.json
        jq -nc --arg ts "$old_ts" '{id:"root1234",ts:$ts,from:"ghost",to:"codex",type:"ack",ref:null,status:"in_progress",paths_claimed:[],body:"working"}' > .agents/bus.jsonl
        CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-inbox" --json > inbox.json
        jq -e 'length == 1 and .[0].stale == true and .[0].stuck == true and .[0].age_minutes >= 10' inbox.json >/dev/null
        CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-inbox" --only-stale --json | jq -e 'length == 1' >/dev/null
        CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-inbox" --only-stuck --json | jq -e 'length == 1' >/dev/null
    )

    pass "agent-inbox reports stale and stuck threads"
}

test_agent_init_syncs_protocol_and_template
test_agent_init_via_symlink
test_install_links_all_commands
test_agent_send_ref_validation
test_agent_send_peer_paths_status_and_signal
test_agent_send_multiline_body
test_agent_done_smoke
test_concurrent_writes_stay_valid
test_agent_inbox_empty_bus
test_agent_cancel_and_resume_smoke
test_agent_inbox_stale_and_stuck

echo "passed $pass_count tests"
