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
surface:3 s3 type=terminal in_window=true
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

make_fake_cmux_live_s1_only() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/cmux" <<'CMUX'
#!/usr/bin/env bash
if [ "$1" = "--id-format" ] && [ "${2:-}" = "both" ] && [ "${3:-}" = "surface-health" ]; then
    cat <<'OUT'
surface:1 s1 type=terminal in_window=true
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
    printf '%s\n' '{"agents":{"codex":"s1","claude":"s2","deepseek":"s3"}}' > .agents/agents.json
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

test_agent_init_rejects_invalid_input() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-init-invalid"
    workspace="$(new_workspace init-invalid)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        for name in 1foo Foo 'foo!' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
            if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" "$name" >/dev/null 2>&1; then
                fail "agent-init accepted invalid name $name"
            fi
        done
        if PATH="$fakebin:$PATH" env -u CMUX_SURFACE_ID "$repo_root/bin/agent-init" codex >/dev/null 2>&1; then
            fail "agent-init accepted missing CMUX_SURFACE_ID"
        fi
    )

    pass "agent-init rejects invalid names and missing surface"
}

test_agent_init_is_idempotent() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-init-idempotent"
    workspace="$(new_workspace init-idempotent)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" codex >/dev/null
        PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" codex >/dev/null
        [ "$(grep -c 'agent-bus:start v1' AGENTS.md)" = "1" ] || fail "AGENTS block duplicated"
        [ "$(grep -cFx ".agents/" .gitignore)" = "1" ] || fail ".gitignore duplicated .agents/"
        jq -e '.agents == {"codex":"s1"}' .agents/agents.json >/dev/null
    )

    pass "agent-init keeps AGENTS.md and .gitignore idempotent"
}

test_install_links_all_commands() {
    local fakebin home tool
    fakebin="$tmp_root/fakebin-install"
    home="$tmp_root/home-install"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    PATH="$fakebin:$PATH" HOME="$home" "$repo_root/install.sh" >/dev/null
    for tool in agent-init agent-send agent-inbox agent-done agent-cancel agent-resume agent-doctor; do
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

test_agent_send_broadcast_fanout() {
    local fakebin workspace cmux_log ids
    fakebin="$tmp_root/fakebin-send-broadcast"
    workspace="$(new_workspace send-broadcast)"
    cmux_log="$tmp_root/cmux-send-broadcast.log"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        ids=$(PATH="$fakebin:$PATH" CMUX_LOG="$cmux_log" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" all ask "broadcast task")
        [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = "2" ] || fail "broadcast did not print two ids"
        [ "$(jq -s length .agents/bus.jsonl)" = "2" ] || fail "broadcast did not append two events"
        jq -s -e '
            length == 2
            and ([.[].to] | sort) == ["claude","deepseek"]
            and all(.[]; .from == "codex" and .type == "ask" and .status == "open" and .body == "broadcast task")
        ' .agents/bus.jsonl >/dev/null
        grep -q "send --surface s2 new ask id=" "$cmux_log"
        grep -q "send --surface s3 new ask id=" "$cmux_log"
    )

    pass "agent-send broadcasts to all peers as fan-out events"
}

test_agent_send_broadcast_rejects_invalid_batch() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-send-broadcast-invalid"
    workspace="$(new_workspace send-broadcast-invalid)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude,missing ask "bad broadcast" >/dev/null 2>&1; then
            fail "broadcast accepted an unknown recipient"
        fi
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"user",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"root"}' > .agents/bus.jsonl
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude,deepseek ask --ref root1234 "bad broadcast" 2>err.out; then
            fail "broadcast accepted --ref"
        fi
        grep -q "broadcast with --ref is not supported" err.out
        : > .agents/bus.jsonl
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude,deepseek handoff "bad broadcast" >/dev/null 2>&1; then
            fail "broadcast accepted a non-ask type"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "0" ] || fail "invalid broadcast appended to bus"
    )

    pass "agent-send rejects invalid broadcast batches without appending"
}

test_agent_send_broadcast_normalizes_recipients() {
    local fakebin workspace ids
    fakebin="$tmp_root/fakebin-send-broadcast-normalize"
    workspace="$(new_workspace send-broadcast-normalize)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        ids=$(PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" "codex, claude, claude" ask "normalized")
        [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = "1" ] || fail "normalized broadcast did not print one id"
        jq -s -e 'length == 1 and .[0].to == "claude" and .[0].from == "codex"' .agents/bus.jsonl >/dev/null
    )

    pass "agent-send filters self and deduplicates broadcast recipients"
}

test_agent_send_broadcast_allows_user_in_csv() {
    local fakebin workspace cmux_log ids
    fakebin="$tmp_root/fakebin-send-broadcast-user"
    workspace="$(new_workspace send-broadcast-user)"
    cmux_log="$tmp_root/cmux-send-broadcast-user.log"
    make_fake_cmux "$fakebin"
    : > "$cmux_log"

    (
        cd "$workspace"
        write_agents
        ids=$(PATH="$fakebin:$PATH" CMUX_LOG="$cmux_log" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude,user ask "agent plus user")
        [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" = "2" ] || fail "agent+user broadcast did not print two ids"
        jq -s -e 'length == 2 and ([.[].to] | sort) == ["claude","user"]' .agents/bus.jsonl >/dev/null
        grep -q "send --surface s2 new ask id=" "$cmux_log"
        [ "$(grep -c "send --surface" "$cmux_log")" = "1" ] || fail "user recipient should not receive a cmux signal"
    )

    pass "agent-send broadcasts to agents and user without signaling user"
}

test_agent_send_broadcast_rejects_stale_batch() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-send-broadcast-stale"
    workspace="$(new_workspace send-broadcast-stale)"
    make_fake_cmux_live_s1_only "$fakebin"

    (
        cd "$workspace"
        write_agents
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" all ask "stale broadcast" >/dev/null 2>&1; then
            fail "broadcast accepted stale recipients"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "0" ] || fail "stale broadcast appended to bus"
    )

    pass "agent-send rejects stale broadcast batches without appending"
}

test_agent_send_rejects_invalid_recipient_type_and_status() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-send-invalid"
    workspace="$(new_workspace send-invalid)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" unknown ask "body" >/dev/null 2>&1; then
            fail "agent-send accepted unknown recipient"
        fi
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude bogus "body" >/dev/null 2>&1; then
            fail "agent-send accepted invalid type"
        fi
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude ask --status weird "body" >/dev/null 2>&1; then
            fail "agent-send accepted invalid status"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "0" ] || fail "invalid agent-send calls appended to bus"
    )

    pass "agent-send rejects invalid recipient, type, and status"
}

test_agent_send_user_does_not_signal() {
    local fakebin workspace cmux_log
    fakebin="$tmp_root/fakebin-send-user"
    workspace="$(new_workspace send-user)"
    cmux_log="$tmp_root/cmux-send-user.log"
    make_fake_cmux "$fakebin"
    : > "$cmux_log"

    (
        cd "$workspace"
        write_agents
        PATH="$fakebin:$PATH" CMUX_LOG="$cmux_log" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user block "to user" >/dev/null
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "1" ] || fail "send to user did not append"
        [ ! -s "$cmux_log" ] || fail "send to user signaled cmux"
    )

    pass "agent-send to user appends without cmux signal"
}

test_agent_send_rejects_stale_recipient() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-send-stale"
    workspace="$(new_workspace send-stale)"
    make_fake_cmux_live_s1_only "$fakebin"

    (
        cd "$workspace"
        write_agents
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" claude ask "body" >/dev/null 2>&1; then
            fail "agent-send accepted stale recipient"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "0" ] || fail "stale recipient appended to bus"
    )

    pass "agent-send rejects stale recipients without appending"
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

test_agent_done_rejects_unknown_id() {
    local workspace
    workspace="$(new_workspace done-missing)"

    (
        cd "$workspace"
        write_agents
        if CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-done" missing99 "done" >/dev/null 2>&1; then
            fail "agent-done accepted unknown id"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "0" ] || fail "agent-done unknown id appended to bus"
    )

    pass "agent-done rejects unknown ids without appending"
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

test_agent_cancel_and_resume_negative_cases() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-recovery-negative"
    workspace="$(new_workspace recovery-negative)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"do work"}' > .agents/bus.jsonl
        jq -nc '{id:"done1234",ts:"2026-05-05T00:01:00Z",from:"claude",to:"codex",type:"done",ref:"root1234",status:"done",paths_claimed:[],body:"done"}' >> .agents/bus.jsonl
        jq -nc '{id:"userroot",ts:"2026-05-05T00:02:00Z",from:"codex",to:"user",type:"block",ref:null,status:"blocked",paths_claimed:[],body:"user root"}' >> .agents/bus.jsonl

        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-cancel" missing99 >/dev/null 2>&1; then
            fail "agent-cancel accepted unknown id"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-resume" missing99 >/dev/null 2>&1; then
            fail "agent-resume accepted unknown id"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-cancel" root1234 >/dev/null 2>&1; then
            fail "agent-cancel accepted done thread without --force"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-resume" root1234 >/dev/null 2>&1; then
            fail "agent-resume accepted done thread without --force"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-resume" userroot >/dev/null 2>&1; then
            fail "agent-resume accepted user recipient"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "3" ] || fail "negative recovery calls appended to bus"
    )

    pass "agent-cancel and agent-resume reject invalid recovery cases"
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

test_agent_doctor_ok_and_summary() {
    local workspace old_ts output
    workspace="$(new_workspace doctor-ok)"
    old_ts="$(date -u -v-20M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '20 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")"

    (
        cd "$workspace"
        mkdir -p .agents
        printf '%s\n' '{"agents":{"codex":"s1"}}' > .agents/agents.json
        jq -nc --arg ts "$old_ts" '{id:"root1234",ts:$ts,from:"ghost",to:"codex",type:"ack",ref:null,status:"in_progress",paths_claimed:[],body:"working"}' > .agents/bus.jsonl
        output=$("$repo_root/bin/agent-doctor")
        printf '%s\n' "$output" | grep -q "agent-doctor: ok"
        printf '%s\n' "$output" | grep -q "events: 1"
        printf '%s\n' "$output" | grep -q "open_threads: 1"
        printf '%s\n' "$output" | grep -q "stale_threads: 1"
        printf '%s\n' "$output" | grep -q "stuck_threads: 1"
    )

    pass "agent-doctor reports ok summary"
}

test_agent_doctor_reports_bus_problems() {
    local workspace
    workspace="$(new_workspace doctor-problems)"

    (
        cd "$workspace"
        mkdir -p .agents
        printf '%s\n' '{"agents":{"codex":"s1"}}' > .agents/agents.json
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"root"}' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:01:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"dupe"}' >> .agents/bus.jsonl
        jq -nc '{id:"child123",ts:"2026-05-05T00:02:00Z",from:"codex",to:"claude",type:"ask",ref:"missing99",status:"open",paths_claimed:[],body:"orphan"}' >> .agents/bus.jsonl
        if "$repo_root/bin/agent-doctor" > doctor.out; then
            fail "agent-doctor accepted duplicate/orphan refs"
        fi
        grep -q "duplicate event id root1234" doctor.out
        grep -q "event child123 references missing id missing99" doctor.out
    )

    pass "agent-doctor reports duplicate ids and orphan refs"
}

test_agent_doctor_reports_malformed_jsonl() {
    local workspace
    workspace="$(new_workspace doctor-malformed)"

    (
        cd "$workspace"
        write_agents
        printf '%s\n' '{"id":"broken"' > .agents/bus.jsonl
        if "$repo_root/bin/agent-doctor" > doctor.out; then
            fail "agent-doctor accepted malformed JSONL"
        fi
        grep -q "line 1: invalid event JSON/schema" doctor.out
    )

    pass "agent-doctor reports malformed JSONL"
}

test_agent_init_syncs_protocol_and_template
test_agent_init_via_symlink
test_agent_init_rejects_invalid_input
test_agent_init_is_idempotent
test_install_links_all_commands
test_agent_send_ref_validation
test_agent_send_peer_paths_status_and_signal
test_agent_send_broadcast_fanout
test_agent_send_broadcast_rejects_invalid_batch
test_agent_send_broadcast_normalizes_recipients
test_agent_send_broadcast_allows_user_in_csv
test_agent_send_broadcast_rejects_stale_batch
test_agent_send_rejects_invalid_recipient_type_and_status
test_agent_send_user_does_not_signal
test_agent_send_rejects_stale_recipient
test_agent_send_multiline_body
test_agent_done_smoke
test_agent_done_rejects_unknown_id
test_concurrent_writes_stay_valid
test_agent_inbox_empty_bus
test_agent_cancel_and_resume_smoke
test_agent_cancel_and_resume_negative_cases
test_agent_inbox_stale_and_stuck
test_agent_doctor_ok_and_summary
test_agent_doctor_reports_bus_problems
test_agent_doctor_reports_malformed_jsonl

echo "passed $pass_count tests"
