#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

pass_count=0
export AGENT_BUS_SCOPE=repo

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
if [ "$1" = "identify" ]; then
    printf '{"caller":{"workspace_id":"%s"}}\n' "${FAKE_CALLER_WS:-}"
    exit 0
fi
if [ "$1" = "current-workspace" ]; then
    printf 'workspace:test\n'
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
if [ "$1" = "identify" ]; then
    printf '{"caller":{"workspace_id":"%s"}}\n' "${FAKE_CALLER_WS:-}"
    exit 0
fi
if [ "$1" = "current-workspace" ]; then
    printf 'workspace:test\n'
    exit 0
fi
exit 0
CMUX
    chmod +x "$dir/cmux"
}

make_fake_cmux_auto_done() {
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
if [ "$1" = "send" ]; then
    if [ -n "${CMUX_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$CMUX_LOG"
    fi
    surface=""
    event_id=""
    from_agent=""
    prev=""
    message=""
    for arg in "$@"; do
        if [ "$prev" = "--surface" ]; then
            surface="$arg"
        elif [ "$prev" = "$surface" ] && [ -n "$surface" ]; then
            message="$arg"
        fi
        prev="$arg"
    done
    for word in $message; do
        case "$word" in
            id=*) event_id="${word#id=}";;
            from=*) from_agent="${word#from=}";;
        esac
    done
    case "$surface" in
        s2) responder="claude";;
        s3) responder="deepseek";;
        *) responder="peer";;
    esac
    status="${CMUX_AUTO_DONE_STATUS:-done}"
    body="${CMUX_AUTO_DONE_BODY:-rpc answer}"
    done_id="${event_id}d"
    jq -nc \
        --arg id "$done_id" \
        --arg ts "2026-05-05T00:01:00Z" \
        --arg from "$responder" \
        --arg to "$from_agent" \
        --arg ref "$event_id" \
        --arg status "$status" \
        --arg body "$body" \
        '{id:$id,ts:$ts,from:$from,to:$to,type:(if $status=="blocked" then "block" else "done" end),ref:$ref,status:$status,paths_claimed:[],body:$body}' >> .agents/bus.jsonl
    exit 0
fi
if [ "$1" = "send-key" ]; then
    if [ -n "${CMUX_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$CMUX_LOG"
    fi
    exit 0
fi
if [ "$1" = "identify" ]; then
    printf '{"caller":{"workspace_id":"%s"}}\n' "${FAKE_CALLER_WS:-}"
    exit 0
fi
if [ "$1" = "current-workspace" ]; then
    printf 'workspace:test\n'
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

test_agent_init_defaults_to_workspace_scope() {
    local fakebin home workspace bus output
    fakebin="$tmp_root/fakebin-init-workspace"
    home="$tmp_root/home-init-workspace"
    workspace="$(new_workspace init-workspace)"
    bus="$home/.local/state/cmux-bus/workspaces/ws-default"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    (
        cd "$workspace"
        env -u AGENT_BUS_SCOPE PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-default CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" codex >/dev/null
        [ -f "$bus/bus.jsonl" ] || fail "workspace bus.jsonl missing"
        [ -f "$bus/agents.json" ] || fail "workspace agents.json missing"
        [ -f "$bus/PROTOCOL.md" ] || fail "workspace PROTOCOL.md missing"
        grep -q "workspace-scope stub" .agents/PROTOCOL.md
        [ ! -e .agents/bus.jsonl ] || fail "workspace scope created a folder-local bus.jsonl"
        [ ! -e .agents/agents.json ] || fail "workspace scope created a folder-local agents.json"
        jq -e '.agents.codex == "s1"' "$bus/agents.json" >/dev/null
        output=$(env -u AGENT_BUS_SCOPE HOME="$home" CMUX_WORKSPACE_ID=ws-default CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-inbox")
        [ "$output" = "agent-inbox: no open threads for codex" ] || fail "workspace inbox did not use default workspace bus: $output"
        env -u AGENT_BUS_SCOPE PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-default CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" codex >/dev/null
        [ "$(find . -maxdepth 1 -type d -name '.agents.repo-legacy-*' | wc -l | tr -d ' ')" = "0" ] || fail "workspace stub was re-archived on second init"
    )

    pass "agent-init defaults to cmux workspace bus"
}

test_scope_cli_overrides_env() {
    local fakebin home workspace bus
    fakebin="$tmp_root/fakebin-scope-override"
    home="$tmp_root/home-scope-override"
    workspace="$(new_workspace scope-override)"
    bus="$home/.local/state/cmux-bus/workspaces/ws-override"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    (
        cd "$workspace"
        PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-override CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" --scope workspace codex >/dev/null
        [ -f "$bus/bus.jsonl" ] || fail "--scope workspace did not override AGENT_BUS_SCOPE=repo"
        grep -q "workspace-scope stub" .agents/PROTOCOL.md
        [ ! -e .agents/bus.jsonl ] || fail "--scope workspace unexpectedly created a folder-local bus"
    )

    pass "command-line scope overrides AGENT_BUS_SCOPE"
}

test_agent_init_isolates_same_folder_across_workspaces() {
    local fakebin home workspace bus_a bus_b cmux_log out_a
    fakebin="$tmp_root/fakebin-multiws"
    home="$tmp_root/home-multiws"
    workspace="$(new_workspace multiws)"
    bus_a="$home/.local/state/cmux-bus/workspaces/ws-a"
    bus_b="$home/.local/state/cmux-bus/workspaces/ws-b"
    cmux_log="$tmp_root/cmux-multiws.log"
    mkdir -p "$fakebin" "$home"

    # One folder open in two cmux workspaces; surfaces of both are live.
    cat > "$fakebin/cmux" <<'CMUX'
#!/usr/bin/env bash
if [ "$1" = "--id-format" ] && [ "${2:-}" = "both" ] && [ "${3:-}" = "surface-health" ]; then
    cat <<'OUT'
surface:1 sa1 type=terminal in_window=true
surface:2 sa2 type=terminal in_window=true
surface:3 sb1 type=terminal in_window=true
surface:4 sb2 type=terminal in_window=true
OUT
    exit 0
fi
if [ "$1" = "send" ] || [ "$1" = "send-key" ]; then
    [ -n "${CMUX_LOG:-}" ] && printf '%s\n' "$*" >> "$CMUX_LOG"
    exit 0
fi
exit 0
CMUX
    chmod +x "$fakebin/cmux"

    (
        cd "$workspace"
        # Each workspace registers an agent named "claude" (and a "codex" peer).
        for spec in "ws-a:claude:sa1" "ws-a:codex:sa2" "ws-b:claude:sb1" "ws-b:codex:sb2"; do
            wsid="${spec%%:*}"; rest="${spec#*:}"; agent="${rest%%:*}"; surf="${rest#*:}"
            env -u AGENT_BUS_SCOPE PATH="$fakebin:$PATH" HOME="$home" \
                CMUX_WORKSPACE_ID="$wsid" CMUX_SURFACE_ID="$surf" \
                "$repo_root/bin/agent-init" "$agent" >/dev/null
        done

        # Two separate buses, no name collision: each "claude" keeps its own surface.
        jq -e '.agents.claude == "sa1"' "$bus_a/agents.json" >/dev/null || fail "ws-a claude surface clobbered"
        jq -e '.agents.claude == "sb1"' "$bus_b/agents.json" >/dev/null || fail "ws-b claude surface clobbered"

        # The shared folder stub must not hardcode either workspace's bus path.
        grep -q "workspace-scope stub" .agents/PROTOCOL.md || fail "stub header missing"
        ! grep -q "workspaces/ws-a" .agents/PROTOCOL.md || fail "stub leaked ws-a bus path"
        ! grep -q "workspaces/ws-b" .agents/PROTOCOL.md || fail "stub leaked ws-b bus path"

        # Each pane's inbox resolves its own workspace bus.
        out_a=$(env -u AGENT_BUS_SCOPE PATH="$fakebin:$PATH" HOME="$home" \
            CMUX_WORKSPACE_ID=ws-a CMUX_SURFACE_ID=sa1 "$repo_root/bin/agent-inbox")
        [ "$out_a" = "agent-inbox: no open threads for claude" ] || fail "ws-a inbox resolved wrong bus: $out_a"

        # Signalling stays inside the workspace: claude@ws-a reaches codex@ws-a (sa2),
        # never the same-named peer in ws-b (sb2).
        env -u AGENT_BUS_SCOPE PATH="$fakebin:$PATH" HOME="$home" CMUX_LOG="$cmux_log" \
            CMUX_WORKSPACE_ID=ws-a CMUX_SURFACE_ID=sa1 \
            "$repo_root/bin/agent-send" codex handoff "ping" >/dev/null
        grep -q "send --surface sa2 " "$cmux_log" || fail "ws-a send did not target its own peer surface"
        ! grep -q "surface sb2" "$cmux_log" || fail "ws-a send leaked into ws-b peer surface"

        # ws-a only knows ws-a peers (codex); ws-b's bus is invisible from here.
        if env -u AGENT_BUS_SCOPE PATH="$fakebin:$PATH" HOME="$home" \
            CMUX_WORKSPACE_ID=ws-a CMUX_SURFACE_ID=sa1 \
            "$repo_root/bin/agent-send" deepseek ask "x" >/dev/null 2>&1; then
            fail "ws-a reached an agent it never registered"
        fi
    )

    pass "agent-init isolates buses when one folder is open in multiple workspaces"
}

test_workspace_id_resolves_caller_not_focused() {
    local fakebin home workspace bus_caller bus_focused
    fakebin="$tmp_root/fakebin-fallback"
    home="$tmp_root/home-fallback"
    workspace="$(new_workspace fallback-ws)"
    bus_caller="$home/.local/state/cmux-bus/workspaces/ws-caller"
    bus_focused="$home/.local/state/cmux-bus/workspaces/test"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    (
        cd "$workspace"
        # CMUX_WORKSPACE_ID unset: resolution must use the caller's workspace via
        # `cmux identify` (ws-caller), not the focused workspace that
        # `cmux current-workspace` reports (workspace:test).
        env -u AGENT_BUS_SCOPE -u CMUX_WORKSPACE_ID PATH="$fakebin:$PATH" HOME="$home" \
            FAKE_CALLER_WS=ws-caller CMUX_SURFACE_ID=s1 \
            "$repo_root/bin/agent-init" codex >/dev/null
        [ -f "$bus_caller/agents.json" ] || fail "fallback did not resolve caller workspace bus"
        [ ! -e "$bus_focused/agents.json" ] || fail "fallback wrongly used focused workspace"
    )

    pass "workspace id resolves the caller workspace, not the focused one"
}

test_agent_init_workspace_archives_closed_legacy_bus_files() {
    local fakebin home workspace archive
    fakebin="$tmp_root/fakebin-init-archive"
    home="$tmp_root/home-init-archive"
    workspace="$(new_workspace init-archive)"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    (
        cd "$workspace"
        mkdir -p .agents/skills/local
        printf '%s\n' "keep me" > .agents/skills/local/README.md
        printf '%s\n' '{"agents":{"codex":"old-surface"}}' > .agents/agents.json
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"old"}' > .agents/bus.jsonl
        jq -nc '{id:"done1234",ts:"2026-05-05T00:01:00Z",from:"codex",to:"claude",type:"done",ref:"root1234",status:"done",paths_claimed:[],body:"done"}' >> .agents/bus.jsonl
        printf '%s\n' "legacy protocol" > .agents/PROTOCOL.md

        PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-archive CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" --scope workspace codex > init.out

        [ ! -e .agents/bus.jsonl ] || fail "legacy bus.jsonl was not archived"
        [ ! -e .agents/agents.json ] || fail "legacy agents.json was not archived"
        grep -q "workspace-scope stub" .agents/PROTOCOL.md
        grep -q "active bus" .agents/README.md
        [ -f .agents/skills/local/README.md ] || fail "non-bus .agents content was moved"
        archive="$(find . -maxdepth 1 -type d -name '.agents.repo-legacy-*' | head -n1)"
        [ -n "$archive" ] || fail "legacy archive directory missing"
        [ -f "$archive/bus.jsonl" ] || fail "archive missing bus.jsonl"
        [ -f "$archive/agents.json" ] || fail "archive missing agents.json"
        grep -q "archived legacy repo bus files" init.out
    )

    pass "agent-init workspace archives closed legacy bus files and writes stub"
}

test_agent_init_workspace_refuses_open_legacy_bus_files() {
    local fakebin home workspace bus
    fakebin="$tmp_root/fakebin-init-refuse-open"
    home="$tmp_root/home-init-refuse-open"
    workspace="$(new_workspace init-refuse-open)"
    bus="$home/.local/state/cmux-bus/workspaces/ws-refuse-open"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    (
        cd "$workspace"
        mkdir -p .agents
        printf '%s\n' '{"agents":{"codex":"old-surface"}}' > .agents/agents.json
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"old"}' > .agents/bus.jsonl
        printf '%s\n' "legacy protocol" > .agents/PROTOCOL.md

        if PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-refuse-open CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" --scope workspace codex > init.out 2> init.err; then
            fail "agent-init switched scope with open legacy threads"
        fi
        grep -q "legacy .agents/bus.jsonl has 1 open thread" init.err
        [ -f .agents/bus.jsonl ] || fail "open legacy bus was moved"
        [ ! -e "$bus/bus.jsonl" ] || fail "workspace bus was created despite refusal"
        ! grep -q "workspace-scope stub" .agents/PROTOCOL.md || fail "stub overwrote open legacy protocol"
    )

    pass "agent-init workspace refuses open legacy bus files"
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

test_agent_init_enforces_one_name_per_surface() {
    local fakebin workspace out
    fakebin="$tmp_root/fakebin-rename"
    workspace="$(new_workspace init-rename)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        # Register, then re-register a different name in the SAME pane (surface).
        PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" jean >/dev/null
        out=$(PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" leo)
        jq -e '.agents == {"leo":"s1"}' .agents/agents.json >/dev/null || fail "rename left a ghost name on the surface"
        printf '%s\n' "$out" | grep -q "replaced previous name(s) on this surface: jean" || fail "rename was not reported"
        # A distinct surface keeps its own name; the renamed one is untouched.
        PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s2 "$repo_root/bin/agent-init" codex >/dev/null
        jq -e '.agents == {"leo":"s1","codex":"s2"}' .agents/agents.json >/dev/null || fail "distinct surface registration affected"
    )

    pass "agent-init keeps one name per surface (rename replaces the old)"
}

test_install_links_all_commands() {
    local fakebin home tool
    fakebin="$tmp_root/fakebin-install"
    home="$tmp_root/home-install"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    PATH="$fakebin:$PATH" HOME="$home" "$repo_root/install.sh" >/dev/null
    for tool in agent-init agent-send agent-inbox agent-done agent-cancel agent-resume agent-doctor agent-repair agent-guard agent-rpc agent-playbook agent-synthesize agent-thread agent-watch agent-wait agent-update; do
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
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"user",to:"codex",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"root"}' >> .agents/bus.jsonl
        CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user done --ref root1234 "valid ref" >/dev/null
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "3" ] || fail "valid ref did not append"
        tail -n 1 .agents/bus.jsonl | jq -e '.ref == "root1234"' >/dev/null

        if CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" user done --ref missing99 "bad ref" 2>"$err_file"; then
            fail "invalid ref unexpectedly succeeded"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "3" ] || fail "invalid ref appended to bus"
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

test_agent_send_unknown_recipient_warns_against_cmux_fallback() {
    local fakebin workspace err_file
    fakebin="$tmp_root/fakebin-send-unknown-message"
    workspace="$(new_workspace send-unknown-message)"
    err_file="$tmp_root/send-unknown-message.err"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        if PATH="$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" missing ask "body" 2>"$err_file"; then
            fail "agent-send accepted missing recipient"
        fi
        grep -q "do not use 'cmux send' as a fallback" "$err_file"
        grep -q "agent-init missing" "$err_file"
    )

    pass "agent-send unknown recipient warns against cmux fallback"
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
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"root"}' >> .agents/bus.jsonl
        done_id=$(PATH="$fakebin:$PATH" CMUX_LOG="$cmux_log" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-done" root1234 "done body")
        [ -n "$done_id" ] || fail "agent-done did not print event id"
        tail -n 1 .agents/bus.jsonl | jq -e '
            .id == $id
            and .type == "done"
            and .ref == "root1234"
            and .to == "claude"
            and .status == "done"
            and .body == "done body"
        ' --arg id "$done_id" >/dev/null
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
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:["src/a.ts"],body:"do work"}' >> .agents/bus.jsonl
        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-resume" root1234 >/dev/null
        tail -n 1 .agents/bus.jsonl | jq -e '.type == "handoff" and .to == "claude" and .ref == "root1234"' >/dev/null
        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-cancel" root1234 "dropping" >/dev/null
        tail -n 1 .agents/bus.jsonl | jq -e '.type == "block" and .to == "user" and .status == "blocked"' >/dev/null
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

test_agent_cancel_resolves_deep_thread_root() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-recovery-deep"
    workspace="$(new_workspace recovery-deep)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"root"}' > .agents/bus.jsonl
        jq -nc '{id:"ack12345",ts:"2026-05-05T00:01:00Z",from:"claude",to:"codex",type:"ack",ref:"root1234",status:"in_progress",paths_claimed:[],body:"ack"}' >> .agents/bus.jsonl
        jq -nc '{id:"note1234",ts:"2026-05-05T00:02:00Z",from:"codex",to:"claude",type:"ask",ref:"ack12345",status:"open",paths_claimed:[],body:"nested"}' >> .agents/bus.jsonl
        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-cancel" note1234 "deep cancel" >/dev/null
        tail -n 1 .agents/bus.jsonl | jq -e '.type == "block" and .to == "user" and .ref == "root1234" and .status == "blocked"' >/dev/null
    )

    pass "agent-cancel resolves deep thread roots"
}

test_agent_inbox_stale_and_stuck() {
    local workspace old_ts
    workspace="$(new_workspace inbox)"
    old_ts="$(date -u -v-20M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '20 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")"

    (
        cd "$workspace"
        mkdir -p .agents
        printf '%s\n' '{"agents":{"codex":"s1"}}' > .agents/agents.json
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc --arg ts "$old_ts" '{id:"root1234",ts:$ts,from:"ghost",to:"codex",type:"ack",ref:null,status:"in_progress",paths_claimed:[],body:"working"}' >> .agents/bus.jsonl
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

test_agent_doctor_reports_workspace_split_brain() {
    local workspace bus
    workspace="$(new_workspace doctor-split-brain)"
    bus="$workspace/workspace-bus"

    (
        cd "$workspace"
        mkdir -p "$bus" .agents
        printf '%s\n' '{"agents":{"codex":"s1"}}' > "$bus/agents.json"
        : > "$bus/bus.jsonl"
        printf '%s\n' '{"agents":{"codex":"old"}}' > .agents/agents.json
        : > .agents/bus.jsonl
        printf '%s\n' "legacy protocol" > .agents/PROTOCOL.md

        if "$repo_root/bin/agent-doctor" --bus-dir "$bus" > doctor.out; then
            fail "agent-doctor accepted split-brain workspace/repo bus"
        fi
        grep -q "legacy .agents/bus.jsonl exists" doctor.out
        grep -q "legacy .agents/agents.json exists" doctor.out
        grep -q "legacy .agents/PROTOCOL.md exists" doctor.out
    )

    pass "agent-doctor reports workspace/repo split-brain"
}

test_agent_repair_dry_run_and_fix() {
    local workspace output
    workspace="$(new_workspace repair)"

    (
        cd "$workspace"
        write_agents
        printf '%s\n' '{"id":"root1234","ts":"2026-05-05T00:00:00Z","from":"claude","to":"codex","type":"ask","ref":null,"status":"open","paths_claimed":[],"body":"line 1' > .agents/bus.jsonl
        printf '%s\n' 'line 2"}' >> .agents/bus.jsonl
        jq -nc '{id:"done1234",ts:"2026-05-05T00:01:00Z",from:"codex",to:"claude",type:"done",ref:"root1234",status:"done",paths_claimed:[],body:"done"}' >> .agents/bus.jsonl

        if "$repo_root/bin/agent-repair" --dry-run > repair.out; then
            fail "agent-repair dry-run should report pending repairs with non-zero exit"
        fi
        grep -q "joined_lines: 1" repair.out
        if "$repo_root/bin/agent-doctor" > doctor.out; then
            fail "agent-doctor accepted malformed bus before repair"
        fi

        output=$("$repo_root/bin/agent-repair")
        printf '%s\n' "$output" | grep -q "wrote repaired bus"
        [ "$(ls .agents/bus.jsonl.bak-* | wc -l | tr -d ' ')" = "1" ] || fail "agent-repair did not create a backup"
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "2" ] || fail "agent-repair did not rewrite two events"
        jq -s -e 'length == 2 and .[0].body == "line 1\nline 2" and .[1].ref == "root1234"' .agents/bus.jsonl >/dev/null
        "$repo_root/bin/agent-doctor" >/dev/null
    )

    pass "agent-repair dry-runs and fixes multiline bus events"
}

test_agent_repair_noop() {
    local workspace output before after
    workspace="$(new_workspace repair-noop)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"ok"}' > .agents/bus.jsonl
        before=$(cat .agents/bus.jsonl)
        output=$("$repo_root/bin/agent-repair")
        after=$(cat .agents/bus.jsonl)
        printf '%s\n' "$output" | grep -q "no repairs needed"
        [ "$before" = "$after" ] || fail "agent-repair changed a clean bus"
        [ "$(find .agents -name 'bus.jsonl.bak-*' | wc -l | tr -d ' ')" = "0" ] || fail "agent-repair created backup for clean bus"
    )

    pass "agent-repair leaves clean buses untouched"
}

test_agent_guard_reports_open_claim_conflicts() {
    local workspace
    workspace="$(new_workspace guard-conflict)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:["src/api.ts","src/*.css"],body:"edit"}' > .agents/bus.jsonl
        if "$repo_root/bin/agent-guard" check --agent codex src/api.ts >/dev/null 2>&1; then
            fail "agent-guard missed exact claim conflict"
        fi
        if "$repo_root/bin/agent-guard" check --agent codex src/main.css >/dev/null 2>&1; then
            fail "agent-guard missed glob claim conflict"
        fi
        "$repo_root/bin/agent-guard" check --agent claude src/api.ts >/dev/null
        "$repo_root/bin/agent-guard" check --agent codex README.md >/dev/null
    )

    pass "agent-guard reports open exact and glob claim conflicts"
}

test_agent_guard_ignores_closed_threads_and_outputs_json() {
    local workspace
    workspace="$(new_workspace guard-closed)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:["src/api.ts"],body:"edit"}' > .agents/bus.jsonl
        jq -nc '{id:"done1234",ts:"2026-05-05T00:01:00Z",from:"claude",to:"codex",type:"done",ref:"root1234",status:"done",paths_claimed:[],body:"done"}' >> .agents/bus.jsonl
        "$repo_root/bin/agent-guard" check --json --all src/api.ts | jq -e 'length == 0' >/dev/null
    )

    pass "agent-guard ignores closed threads and supports JSON output"
}

test_agent_guard_checks_staged_paths() {
    local workspace
    workspace="$(new_workspace guard-staged)"

    (
        cd "$workspace"
        git init -q
        git config user.email test@example.com
        git config user.name Test
        write_agents
        mkdir -p src
        printf '%s\n' "initial" > src/api.ts
        git add src/api.ts
        git commit -qm initial
        printf '%s\n' "changed" > src/api.ts
        git add src/api.ts
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:["src/api.ts"],body:"edit"}' > .agents/bus.jsonl
        if "$repo_root/bin/agent-guard" check --staged --agent codex >/dev/null 2>&1; then
            fail "agent-guard missed staged claim conflict"
        fi
    )

    pass "agent-guard checks staged git paths"
}

test_agent_guard_normalizes_dot_slash_and_ignores_ack_claims() {
    local workspace
    workspace="$(new_workspace guard-normalize)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:["./src/api.ts"],body:"edit"}' > .agents/bus.jsonl
        if "$repo_root/bin/agent-guard" check --agent codex src/api.ts >/dev/null 2>&1; then
            fail "agent-guard did not normalize ./ claim prefixes"
        fi

        jq -nc '{id:"root2222",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"handoff",ref:null,status:"open",paths_claimed:[],body:"edit"}' > .agents/bus.jsonl
        jq -nc '{id:"ack2222",ts:"2026-05-05T00:01:00Z",from:"claude",to:"codex",type:"ack",ref:"root2222",status:"in_progress",paths_claimed:["src/ack.ts"],body:"ack"}' >> .agents/bus.jsonl
        "$repo_root/bin/agent-guard" check --agent codex src/ack.ts >/dev/null
    )

    pass "agent-guard normalizes ./ prefixes and ignores non-handoff claims"
}

test_agent_guard_uses_event_cwd_in_workspace_scope() {
    local fakebin home root_a root_b
    fakebin="$tmp_root/fakebin-guard-cwd"
    home="$tmp_root/home-guard-cwd"
    root_a="$(new_workspace guard-cwd-a)"
    root_b="$(new_workspace guard-cwd-b)"
    make_fake_cmux "$fakebin"
    mkdir -p "$home"

    (
        cd "$root_a"
        PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-guard-cwd CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-init" --scope workspace codex >/dev/null
    )
    (
        cd "$root_b"
        PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-guard-cwd CMUX_SURFACE_ID=s2 "$repo_root/bin/agent-init" --scope workspace claude >/dev/null
    )

    (
        cd "$root_a"
        PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-guard-cwd CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-send" --scope workspace claude handoff --paths "src/api.ts" "edit a" >/dev/null
        if PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-guard-cwd CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-guard" --scope workspace check --agent codex src/api.ts >/dev/null 2>&1; then
            fail "agent-guard missed same-cwd workspace claim"
        fi
    )

    (
        cd "$root_b"
        PATH="$fakebin:$PATH" HOME="$home" CMUX_WORKSPACE_ID=ws-guard-cwd CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-guard" --scope workspace check --agent codex src/api.ts >/dev/null
    )

    pass "agent-guard interprets workspace claims relative to event cwd"
}

test_agent_guard_install_preserves_existing_hooks() {
    local workspace
    workspace="$(new_workspace guard-install)"

    (
        cd "$workspace"
        git init -q
        mkdir -p .git/hooks
        printf '%s\n' '#!/usr/bin/env bash' 'echo lint' > .git/hooks/pre-commit
        chmod +x .git/hooks/pre-commit
        if "$repo_root/bin/agent-guard" install >/dev/null 2>&1; then
            fail "agent-guard install overwrote existing hook without --force"
        fi
        grep -q "echo lint" .git/hooks/pre-commit

        "$repo_root/bin/agent-guard" install --force >/dev/null
        grep -q "agent-guard check --staged >/dev/null" .git/hooks/pre-commit
        if ! "$repo_root/bin/agent-guard" install > install.out; then
            fail "agent-guard install was not idempotent"
        fi
        grep -q "hook already installed" install.out
        [ "$(grep -c "agent-guard check --staged" .git/hooks/pre-commit)" = "1" ] || fail "agent-guard duplicated hook command"
    )

    pass "agent-guard install preserves and idempotently detects hooks"
}

test_agent_thread_shows_history() {
    local workspace output
    workspace="$(new_workspace thread-history)"

    (
        cd "$workspace"
        write_agents
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"handoff",ref:null,status:"open",paths_claimed:["src/a.ts"],body:"root body"}' >> .agents/bus.jsonl
        jq -nc '{id:"ack12345",ts:"2026-05-05T00:01:00Z",from:"codex",to:"claude",type:"ack",ref:"root1234",status:"in_progress",paths_claimed:[],body:"working"}' >> .agents/bus.jsonl
        jq -nc '{id:"done1234",ts:"2026-05-05T00:02:00Z",from:"codex",to:"claude",type:"done",ref:"root1234",status:"done",paths_claimed:[],body:"done body"}' >> .agents/bus.jsonl
        output=$("$repo_root/bin/agent-thread" ack12345)
        printf '%s\n' "$output" | grep -q "thread: root1234"
        printf '%s\n' "$output" | grep -q "events: 3"
        printf '%s\n' "$output" | grep -q "status: done"
        printf '%s\n' "$output" | grep -q "root body"
        printf '%s\n' "$output" | grep -q "done body"
    )

    pass "agent-thread shows full thread history"
}

test_agent_thread_json_and_unknown_id() {
    local workspace
    workspace="$(new_workspace thread-json)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"question"}' > .agents/bus.jsonl
        "$repo_root/bin/agent-thread" --json root1234 > thread.json
        jq -e 'length == 1 and .[0].id == "root1234" and .[0].root == "root1234"' thread.json >/dev/null
        if "$repo_root/bin/agent-thread" missing99 >/dev/null 2>&1; then
            fail "agent-thread accepted unknown id"
        fi
    )

    pass "agent-thread supports JSON output and rejects unknown ids"
}

test_agent_watch_snapshot() {
    local workspace output
    workspace="$(new_workspace watch-snapshot)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"first"}' > .agents/bus.jsonl
        jq -nc '{id:"ack12345",ts:"2026-05-05T00:01:00Z",from:"codex",to:"claude",type:"ack",ref:"root1234",status:"in_progress",paths_claimed:[],body:"second line"}' >> .agents/bus.jsonl
        output=$("$repo_root/bin/agent-watch" --once --lines 1)
        printf '%s\n' "$output" | grep -q "ack12345"
        printf '%s\n' "$output" | grep -q "codex->claude"
        printf '%s\n' "$output" | grep -q "second line"
        if printf '%s\n' "$output" | grep -q "root1234"; then
            fail "agent-watch --lines 1 printed older events"
        fi
    )

    pass "agent-watch renders a bounded snapshot"
}

test_agent_watch_filters_current_agent() {
    local workspace output
    workspace="$(new_workspace watch-me)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"forcodex",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"for codex"}' > .agents/bus.jsonl
        jq -nc '{id:"otherone",ts:"2026-05-05T00:01:00Z",from:"claude",to:"deepseek",type:"ask",ref:null,status:"open",paths_claimed:[],body:"for other"}' >> .agents/bus.jsonl
        output=$(CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-watch" --once --me --lines 0)
        printf '%s\n' "$output" | grep -q "forcodex"
        if printf '%s\n' "$output" | grep -q "otherone"; then
            fail "agent-watch --me printed unrelated events"
        fi
    )

    pass "agent-watch filters events for the current agent"
}

test_agent_watch_rejects_zero_interval() {
    local workspace
    workspace="$(new_workspace watch-zero-interval)"

    (
        cd "$workspace"
        write_agents
        if "$repo_root/bin/agent-watch" --interval 0 >/dev/null 2>&1; then
            fail "agent-watch accepted zero interval"
        fi
    )

    pass "agent-watch rejects zero polling interval"
}

test_agent_watch_skips_malformed_lines() {
    local workspace output
    workspace="$(new_workspace watch-malformed)"

    (
        cd "$workspace"
        write_agents
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"valid event"}' >> .agents/bus.jsonl
        output=$("$repo_root/bin/agent-watch" --once --lines 0)
        printf '%s\n' "$output" | grep -q "root1234"
        printf '%s\n' "$output" | grep -q "valid event"
    )

    pass "agent-watch skips malformed bus lines"
}

test_agent_watch_truncates_long_bodies_unless_full() {
    local workspace output full_output
    workspace="$(new_workspace watch-truncate)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:("x" * 140)}' > .agents/bus.jsonl
        output=$("$repo_root/bin/agent-watch" --once --lines 0)
        printf '%s\n' "$output" | grep -q "xxx..."
        if printf '%s\n' "$output" | grep -q "$(printf 'x%.0s' $(seq 1 140))"; then
            fail "agent-watch printed full long body by default"
        fi
        full_output=$("$repo_root/bin/agent-watch" --once --full --lines 0)
        printf '%s\n' "$full_output" | grep -q "$(printf 'x%.0s' $(seq 1 140))"
    )

    pass "agent-watch truncates long bodies unless --full is used"
}

test_agent_watch_accepts_no_color() {
    local workspace output
    workspace="$(new_workspace watch-no-color)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"plain"}' > .agents/bus.jsonl
        output=$("$repo_root/bin/agent-watch" --once --no-color --lines 0)
        printf '%s\n' "$output" | grep -q "root1234"
        printf '%s\n' "$output" | grep -q "ask  /open"
    )

    pass "agent-watch accepts no-color mode"
}

test_agent_watch_clear_truncates_bus_before_snapshot() {
    local workspace output
    workspace="$(new_workspace watch-clear)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"old event"}' > .agents/bus.jsonl
        output=$("$repo_root/bin/agent-watch" --once --clear --lines 0)
        if printf '%s\n' "$output" | grep -q "root1234"; then
            fail "agent-watch --clear printed old events"
        fi
        [ "$(wc -l < .agents/bus.jsonl | tr -d ' ')" = "0" ] || fail "agent-watch --clear did not truncate bus"
    )

    pass "agent-watch --clear truncates the bus before watching"
}

test_agent_wait_returns_final_event() {
    local workspace
    workspace="$(new_workspace wait-final)"

    (
        cd "$workspace"
        write_agents
        printf '%s\n' 'not json' > .agents/bus.jsonl
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"question"}' >> .agents/bus.jsonl
        jq -nc '{id:"done1234",ts:"2026-05-05T00:01:00Z",from:"codex",to:"claude",type:"done",ref:"root1234",status:"done",paths_claimed:[],body:"answer"}' >> .agents/bus.jsonl
        "$repo_root/bin/agent-wait" root1234 > wait.json
        jq -e '.id == "done1234" and .status == "done" and .root == "root1234" and .body == "answer"' wait.json >/dev/null
        "$repo_root/bin/agent-wait" --status done done1234 | jq -e '.id == "done1234"' >/dev/null
    )

    pass "agent-wait returns the final event for a completed thread"
}

test_agent_wait_timeout_and_unknown_id() {
    local workspace
    workspace="$(new_workspace wait-timeout)"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1234",ts:"2026-05-05T00:00:00Z",from:"claude",to:"codex",type:"ask",ref:null,status:"open",paths_claimed:[],body:"question"}' > .agents/bus.jsonl
        if "$repo_root/bin/agent-wait" --timeout 0 --interval 0.1 root1234 >/dev/null 2>&1; then
            fail "agent-wait did not time out"
        fi
        if "$repo_root/bin/agent-wait" missing99 >/dev/null 2>&1; then
            fail "agent-wait accepted unknown id"
        fi
    )

    pass "agent-wait times out and rejects unknown ids"
}

test_agent_rpc_prints_response_body() {
    local fakebin workspace output
    fakebin="$tmp_root/fakebin-rpc-body"
    workspace="$(new_workspace rpc-body)"
    make_fake_cmux_auto_done "$fakebin"

    (
        cd "$workspace"
        write_agents
        output=$(PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_BODY="rpc ok" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" claude "please answer")
        [ "$output" = "rpc ok" ] || fail "agent-rpc did not print final body"
        jq -s -e '
            length == 2
            and .[0].type == "ask"
            and .[0].from == "codex"
            and .[0].to == "claude"
            and .[0].body == "please answer"
            and .[1].status == "done"
            and .[1].ref == .[0].id
        ' .agents/bus.jsonl >/dev/null
    )

    pass "agent-rpc sends an ask and prints the response body"
}

test_agent_rpc_json_and_blocked_status() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-rpc-json"
    workspace="$(new_workspace rpc-json)"
    make_fake_cmux_auto_done "$fakebin"

    (
        cd "$workspace"
        write_agents
        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_BODY="json ok" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" --json claude "json please" |
            jq -e '.status == "done" and .body == "json ok" and .root' >/dev/null

        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_STATUS=blocked CMUX_AUTO_DONE_BODY="blocked reason" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" claude "may block" > blocked.out; then
            fail "agent-rpc returned success for blocked final status"
        fi
        grep -qxF "blocked reason" blocked.out

        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_STATUS=blocked CMUX_AUTO_DONE_BODY="expected block" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" --status blocked claude "expect block" > expected-block.out
        grep -qxF "expected block" expected-block.out
    )

    pass "agent-rpc supports JSON output and fails on blocked replies"
}

test_agent_rpc_rejects_invalid_recipients() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-rpc-invalid"
    workspace="$(new_workspace rpc-invalid)"
    make_fake_cmux "$fakebin"

    (
        cd "$workspace"
        write_agents
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" all "bad" >/dev/null 2>&1; then
            fail "agent-rpc accepted broadcast recipient"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" claude,deepseek "bad" >/dev/null 2>&1; then
            fail "agent-rpc accepted CSV broadcast recipient"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" user "bad" >/dev/null 2>&1; then
            fail "agent-rpc accepted user recipient"
        fi
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-rpc" unknown "bad" >/dev/null 2>err.out; then
            fail "agent-rpc accepted unknown recipient"
        fi
        grep -q "unknown recipient 'unknown'" err.out
    )

    pass "agent-rpc rejects broadcast and user recipients"
}

test_agent_playbook_runs_json_workflow() {
    local fakebin workspace output
    fakebin="$tmp_root/fakebin-playbook-run"
    workspace="$(new_workspace playbook-run)"
    make_fake_cmux_auto_done "$fakebin"

    (
        cd "$workspace"
        write_agents
        mkdir -p .agents/playbooks
        cat > .agents/playbooks/review-qa.json <<'JSON'
{
  "steps": [
    {"rpc": {"to": "claude", "body": "Review {{task}}", "save": "review"}},
    {"rpc": {"to": "deepseek", "body": "QA {{task}} after {{review_body}}", "save": "qa"}},
    {"print": "review={{review_body}}\nqa={{qa_body}}"}
  ]
}
JSON
        output=$(PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_BODY="agent reply" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-playbook" run review-qa task="ship rpc")
        printf '%s\n' "$output" | grep -qxF "review=agent reply"
        printf '%s\n' "$output" | grep -qxF "qa=agent reply"
        jq -s -e '
            length == 4
            and .[0].to == "claude"
            and .[0].body == "Review ship rpc"
            and .[2].to == "deepseek"
            and .[2].body == "QA ship rpc after agent reply"
        ' .agents/bus.jsonl >/dev/null
    )

    pass "agent-playbook runs JSON rpc workflows with interpolation"
}

test_agent_playbook_send_wait_and_path_file() {
    local fakebin workspace output playbook_path
    fakebin="$tmp_root/fakebin-playbook-send"
    workspace="$(new_workspace playbook-send)"
    make_fake_cmux_auto_done "$fakebin"

    (
        cd "$workspace"
        write_agents
        playbook_path="$workspace/direct.json"
        cat > "$playbook_path" <<'JSON'
{
  "steps": [
    {"send": {"to": "claude", "type": "ask", "body": "Question {{topic}}", "save": "question_id"}},
    {"wait": {"id": "{{question_id}}", "save": "answer"}},
    {"print": "{{answer_status}}:{{answer_body}}"}
  ]
}
JSON
        output=$(PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_BODY="wait reply" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-playbook" run "$playbook_path" topic="guards")
        [ "$output" = "done:wait reply" ] || fail "agent-playbook did not print waited answer"
    )

    pass "agent-playbook supports send/wait and explicit playbook paths"
}

test_agent_playbook_rejects_invalid_inputs() {
    local workspace
    workspace="$(new_workspace playbook-invalid)"

    (
        cd "$workspace"
        write_agents
        mkdir -p .agents/playbooks
        printf '%s\n' '{"steps":[{"bogus":{}}]}' > .agents/playbooks/bogus.json
        printf '%s\n' '{"steps":[{"send":{},"rpc":{}}]}' > .agents/playbooks/multi-key.json
        printf '%s\n' '{"no_steps":[]}' > .agents/playbooks/no-steps.json
        if "$repo_root/bin/agent-playbook" run missing >/dev/null 2>&1; then
            fail "agent-playbook accepted missing playbook"
        fi
        if "$repo_root/bin/agent-playbook" run no-steps >/dev/null 2>&1; then
            fail "agent-playbook accepted playbook without steps"
        fi
        if "$repo_root/bin/agent-playbook" run bogus >/dev/null 2>&1; then
            fail "agent-playbook accepted unsupported step"
        fi
        if "$repo_root/bin/agent-playbook" run multi-key >/dev/null 2>&1; then
            fail "agent-playbook accepted multi-key step"
        fi
        if "$repo_root/bin/agent-playbook" run bogus badvar >/dev/null 2>&1; then
            fail "agent-playbook accepted malformed variable"
        fi
    )

    pass "agent-playbook rejects missing playbooks and invalid inputs"
}

test_agent_synthesize_collects_threads() {
    local fakebin workspace output
    fakebin="$tmp_root/fakebin-synthesize"
    workspace="$(new_workspace synthesize)"
    make_fake_cmux_auto_done "$fakebin"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1111",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"ask",ref:null,status:"open",paths_claimed:[],body:"opinion?"}' > .agents/bus.jsonl
        jq -nc '{id:"done1111",ts:"2026-05-05T00:01:00Z",from:"claude",to:"codex",type:"done",ref:"root1111",status:"done",paths_claimed:[],body:"claude says playbook"}' >> .agents/bus.jsonl
        jq -nc '{id:"root2222",ts:"2026-05-05T00:00:00Z",from:"codex",to:"deepseek",type:"ask",ref:null,status:"open",paths_claimed:[],body:"opinion?"}' >> .agents/bus.jsonl
        jq -nc '{id:"done2222",ts:"2026-05-05T00:01:00Z",from:"deepseek",to:"codex",type:"done",ref:"root2222",status:"done",paths_claimed:[],body:"deepseek says guard"}' >> .agents/bus.jsonl

        output=$(PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_BODY="synth result" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-synthesize" --agent deepseek root1111 root2222)
        [ "$output" = "synth result" ] || fail "agent-synthesize did not print synthesis body"
        jq -s -e '
            length == 6
            and .[4].to == "deepseek"
            and (. [4].body | contains("claude says playbook"))
            and (. [4].body | contains("deepseek says guard"))
            and (. [4].body | contains("Consensus"))
            and (. [4].body | contains("<<<THREAD root=root1111 from=claude status=done>>>"))
            and (. [4].body | contains("<<<END_THREAD>>>"))
        ' .agents/bus.jsonl >/dev/null
    )

    pass "agent-synthesize collects final thread replies"
}

test_agent_synthesize_json_and_unknown_id() {
    local fakebin workspace
    fakebin="$tmp_root/fakebin-synthesize-json"
    workspace="$(new_workspace synthesize-json)"
    make_fake_cmux_auto_done "$fakebin"

    (
        cd "$workspace"
        write_agents
        jq -nc '{id:"root1111",ts:"2026-05-05T00:00:00Z",from:"codex",to:"claude",type:"ask",ref:null,status:"open",paths_claimed:[],body:"opinion?"}' > .agents/bus.jsonl
        jq -nc '{id:"done1111",ts:"2026-05-05T00:01:00Z",from:"claude",to:"codex",type:"done",ref:"root1111",status:"done",paths_claimed:[],body:"claude answer"}' >> .agents/bus.jsonl

        PATH="$repo_root/bin:$fakebin:$PATH" CMUX_AUTO_DONE_BODY="json synth" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-synthesize" --json root1111 |
            jq -e '.status == "done" and .body == "json synth"' >/dev/null
        if PATH="$repo_root/bin:$fakebin:$PATH" CMUX_SURFACE_ID=s1 "$repo_root/bin/agent-synthesize" missing99 >/dev/null 2>&1; then
            fail "agent-synthesize accepted unknown thread id"
        fi
    )

    pass "agent-synthesize supports JSON output and rejects unknown ids"
}

test_agent_init_syncs_protocol_and_template
test_agent_init_via_symlink
test_agent_init_defaults_to_workspace_scope
test_scope_cli_overrides_env
test_agent_init_isolates_same_folder_across_workspaces
test_workspace_id_resolves_caller_not_focused
test_agent_init_workspace_archives_closed_legacy_bus_files
test_agent_init_workspace_refuses_open_legacy_bus_files
test_agent_init_rejects_invalid_input
test_agent_init_is_idempotent
test_agent_init_enforces_one_name_per_surface
test_install_links_all_commands
test_agent_send_ref_validation
test_agent_send_peer_paths_status_and_signal
test_agent_send_broadcast_fanout
test_agent_send_broadcast_rejects_invalid_batch
test_agent_send_broadcast_normalizes_recipients
test_agent_send_broadcast_allows_user_in_csv
test_agent_send_broadcast_rejects_stale_batch
test_agent_send_rejects_invalid_recipient_type_and_status
test_agent_send_unknown_recipient_warns_against_cmux_fallback
test_agent_send_user_does_not_signal
test_agent_send_rejects_stale_recipient
test_agent_send_multiline_body
test_agent_done_smoke
test_agent_done_rejects_unknown_id
test_concurrent_writes_stay_valid
test_agent_inbox_empty_bus
test_agent_cancel_and_resume_smoke
test_agent_cancel_and_resume_negative_cases
test_agent_cancel_resolves_deep_thread_root
test_agent_inbox_stale_and_stuck
test_agent_doctor_ok_and_summary
test_agent_doctor_reports_bus_problems
test_agent_doctor_reports_malformed_jsonl
test_agent_doctor_reports_workspace_split_brain
test_agent_repair_dry_run_and_fix
test_agent_repair_noop
test_agent_guard_reports_open_claim_conflicts
test_agent_guard_ignores_closed_threads_and_outputs_json
test_agent_guard_checks_staged_paths
test_agent_guard_normalizes_dot_slash_and_ignores_ack_claims
test_agent_guard_uses_event_cwd_in_workspace_scope
test_agent_guard_install_preserves_existing_hooks
test_agent_thread_shows_history
test_agent_thread_json_and_unknown_id
test_agent_watch_snapshot
test_agent_watch_filters_current_agent
test_agent_watch_rejects_zero_interval
test_agent_watch_skips_malformed_lines
test_agent_watch_truncates_long_bodies_unless_full
test_agent_watch_accepts_no_color
test_agent_watch_clear_truncates_bus_before_snapshot
test_agent_wait_returns_final_event
test_agent_wait_timeout_and_unknown_id
test_agent_rpc_prints_response_body
test_agent_rpc_json_and_blocked_status
test_agent_rpc_rejects_invalid_recipients
test_agent_playbook_runs_json_workflow
test_agent_playbook_send_wait_and_path_file
test_agent_playbook_rejects_invalid_inputs
test_agent_synthesize_collects_threads
test_agent_synthesize_json_and_unknown_id

echo "passed $pass_count tests"
