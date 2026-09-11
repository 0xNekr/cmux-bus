#!/usr/bin/env bash
# Real Git worktrees; simulated cmux executes the actual child bootstrap.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
export AGENT_BUS_NO_WATCHDOG=1 AGENT_BUS_NOTIFY_AUTO=0 AGENT_SPAWN_SETTLE=0
export AGENT_BUS_PROVIDERS_FILE="$scratch/no-providers" AGENT_BUS_POLICY_FILE="$scratch/no-policy"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
export CMUX_WORKSPACE_ID=workspace-test CMUX_SURFACE_ID=s-lead
export PATH="$repo_root/bin:$scratch/bin:$PATH"
mkdir -p "$scratch/bin"
cat > "$scratch/bin/cmux" <<'CMUX'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --id-format ]; then
    printf 'surface:1 s-lead type=terminal in_window=true\n'
    while read -r id; do printf 'surface:%s s-%s type=terminal in_window=true\n' "$id" "$id"; done < "$FAKE_STATE/live"
    exit 0
fi
case "$1" in
    new-surface|new-split)
        id=$(( $(cat "$FAKE_STATE/next") + 1 ))
        printf '%s\n' "$id" > "$FAKE_STATE/next"
        printf '%s\n' "$id" >> "$FAKE_STATE/live"
        printf 'OK surface:%s workspace:test\n' "$id";;
    send)
        surface="$3"; msg="$4"
        printf '%s\n' "$msg" >> "$FAKE_STATE/messages"
        case "$msg" in
            'cd '*|agent-init*) CMUX_SURFACE_ID="s-${surface#surface:}" bash -c "$msg" >> "$FAKE_STATE/bootstrap.log" 2>&1;;
        esac;;
    close-surface)
        surface="${3#s-}"
        awk -v id="$surface" '$0 != id' "$FAKE_STATE/live" > "$FAKE_STATE/live.tmp"
        mv "$FAKE_STATE/live.tmp" "$FAKE_STATE/live";;
    identify) printf '{"caller":{"workspace_id":"workspace-test","pane_ref":"pane:1"}}\n';;
esac
exit 0
CMUX
cat > "$scratch/bin/codex" <<'PROVIDER'
#!/usr/bin/env bash
jq -n --arg cwd "$PWD" --arg bus "$AGENT_BUS_DIR" --arg flags "$*" '{cwd:$cwd,bus:$bus,flags:$flags}' > "$FAKE_STATE/launch-$CMUX_SURFACE_ID.json"
PROVIDER
cp "$scratch/bin/codex" "$scratch/bin/claude"
chmod +x "$scratch/bin/"*
fail() { echo "not ok - $*" >&2; exit 1; }
ok() { echo "ok - $*"; }
reject() { if "$@" > "$scratch/rejected.log" 2>&1; then fail "unexpected success: $*"; fi; }
setup() {
    project="$scratch/$1/project with spaces and 'quote'"
    export FAKE_STATE="$scratch/$1/cmux" AGENT_BUS_DIR="$scratch/$1/bus with spaces"
    mkdir -p "$project" "$FAKE_STATE" "$AGENT_BUS_DIR"
    printf '10\n' > "$FAKE_STATE/next"; : > "$FAKE_STATE/live"
    git -C "$project" init -q
    printf 'original\n' > "$project/shared.txt"
    printf '.env\ncache/\n.agents/\n' > "$project/.gitignore"
    git -C "$project" add .
    git -C "$project" commit -qm base
    cd "$project"
    agent-init --no-files --lead lead >/dev/null
}
finish() {
    local worker="$1" id="$2" surface path
    surface="$(jq -r --arg n "$worker" '.agents[$n]' "$AGENT_BUS_DIR/agents.json")"
    path="$(agent-worktree path "$worker")"
    (cd "$path" && CMUX_SURFACE_ID="$surface" agent-done "$id" 'committed and checked') >/dev/null
    agent-dismiss "$worker" >/dev/null
}

setup isolation
base="$(git rev-parse HEAD)"
printf 'uncommitted main edit\n' > shared.txt
printf 'local secret\n' > .env
agent-spawn --as codex --worktree --task 'change shared' --paths shared.txt alice >/dev/null
agent-spawn --as claude --worktree --task 'change shared too' --paths shared.txt bob >/dev/null
a="$(agent-worktree path alice)"; b="$(agent-worktree path bob)"
[ "$a" != "$b" ] || fail 'workers share a checkout'
[ "$(cat "$a/shared.txt")" = original ] || fail 'dirty source edits copied'
[ ! -e "$a/.env" ] || fail 'ignored source file copied'
[ ! -e "$a/AGENTS.md" ] || fail 'bootstrap dirtied tracked files'
[ -z "$(git -C "$a" status --porcelain)" ] || fail 'bootstrap left changes'
asurf="$(jq -r '.agents.alice' "$AGENT_BUS_DIR/agents.json")"
jq -e --arg p "$a" --arg bus "$AGENT_BUS_DIR" '.cwd == $p and .bus == $bus and (.flags | contains("filesystem"))' "$FAKE_STATE/launch-$asurf.json" >/dev/null
agent-roster --json | jq -e --arg a "$a" '.agents[] | select(.name == "alice") | .worktree == $a and .branch != null' >/dev/null
aid="$(jq -r 'select(.to == "alice") | .id' "$AGENT_BUS_DIR/bus.jsonl")"
bid="$(jq -r 'select(.to == "bob") | .id' "$AGENT_BUS_DIR/bus.jsonl")"
jq -e --arg p "$a" --arg src "$project" 'select(.to == "alice") | .cwd == $src and .claims_cwd == $p and .worktree.path == $p' "$AGENT_BUS_DIR/bus.jsonl" >/dev/null
(cd "$a" && agent-guard check --agent alice shared.txt)
(cd "$b" && agent-guard check --agent bob shared.txt)
reject agent-guard check --all "$a/shared.txt"
reject agent-send alice handoff --paths "$project/shared.txt" 'bad absolute claim'
reject agent-send alice handoff --paths '../shared.txt' 'bad escaping claim'
agent-guard check --all "$project/shared.txt"
reject agent-worktree integrate alice
reject agent-init alice
printf 'alice\n' > "$a/alice.txt"
git -C "$a" add alice.txt; git -C "$a" commit -qm alice
printf 'bob\n' > "$b/bob.txt"
git -C "$b" add bob.txt; git -C "$b" commit -qm bob
finish alice "$aid"; finish bob "$bid"
tail -n1 "$AGENT_BUS_DIR/bus.jsonl" | jq -e '.worktree.head != null and .worktree.dirty == false' >/dev/null
[ -f "$a/alice.txt" ] || fail 'dismiss removed the worktree'
agent-worktree integrate alice --check 'test -f alice.txt' >/dev/null
agent-worktree integrate bob --check 'test -f alice.txt && test -f bob.txt' >/dev/null
target="$(agent-worktree show bob --json | jq -r '.integration.path')"
[ "$(git rev-parse HEAD)" = "$base" ] || fail 'integration changed main HEAD'
[ "$(cat shared.txt)" = 'uncommitted main edit' ] || fail 'integration changed main edits'
[ -f "$target/alice.txt" ] && [ -f "$target/bob.txt" ] || fail 'combined integration missing work'
abranch="$(git -C "$a" symbolic-ref --short HEAD)"
agent-worktree remove alice >/dev/null
[ ! -d "$a" ] || fail 'clean integrated checkout not removed'
git show-ref --verify "refs/heads/$abranch" >/dev/null
agent-worktree list --json | jq -e 'length == 2 and any(.[]; .name == "alice" and .status == "removed")' >/dev/null
ok 'isolated launches, claims, delivery, two-worker integration and safe cleanup'

setup resume
agent-spawn --as codex --worktree --task task --paths shared.txt worker >/dev/null
w="$(agent-worktree path worker)"
printf 'unfinished\n' >> "$w/shared.txt"
id="$(head -n1 "$AGENT_BUS_DIR/bus.jsonl" | jq -r .id)"
agent-dismiss worker >/dev/null
reject agent-worktree remove worker --keep-branch
reject agent-spawn --as codex worker
agent-spawn --as codex --worktree --no-say worker >/dev/null
[ "$(agent-worktree path worker)" = "$w" ] || fail 'resume changed checkout'
grep -q unfinished "$w/shared.txt" || fail 'resume discarded edits'
agent-resume --force "$id" >/dev/null
tail -n1 "$AGENT_BUS_DIR/bus.jsonl" | jq -e --arg p "$w" '.paths_claimed == ["shared.txt"] and .claims_cwd == $p' >/dev/null
# Expire only the initial attempt; the fresh resume must survive watchdog scan.
jq -c 'if .ref == null then .created_at = 1 | .ttl = 1 | .ack_by = 1 else . end' "$AGENT_BUS_DIR/bus.jsonl" > "$scratch/events"
mv "$scratch/events" "$AGENT_BUS_DIR/bus.jsonl"
before="$(wc -l < "$AGENT_BUS_DIR/bus.jsonl")"
agent-watchdog scan >/dev/null
[ "$(wc -l < "$AGENT_BUS_DIR/bus.jsonl")" = "$before" ] || fail 'resumed handoff immediately expired'
agent-dismiss worker >/dev/null
agent-spawn --as codex --worktree --no-say other >/dev/null
agent-recover "$id" >/dev/null
tail -n1 "$AGENT_BUS_DIR/bus.jsonl" | jq -e '.to == "user" and (.body | contains("Retained worktree"))' >/dev/null
grep -q unfinished "$w/shared.txt" || fail 'recovery lost unfinished work'
ok 'restart preserves dirty work and recovery keeps the original checkout'

setup conflicts
one="$(agent-worktree create one)"; two="$(agent-worktree create two)"
printf 'one\n' > "$one/shared.txt"; git -C "$one" commit -qam one
printf 'two\n' > "$two/shared.txt"; git -C "$two" commit -qam two
agent-worktree integrate one >/dev/null
target="$(agent-worktree show one --json | jq -r '.integration.path')"
old="$(git -C "$target" rev-parse HEAD)"
reject agent-worktree integrate two
[ "$(git -C "$target" rev-parse HEAD)" = "$old" ] || fail 'conflict committed'
git -C "$target" diff --name-only --diff-filter=U | grep -qx shared.txt
git -C "$target" merge --abort
reject agent-worktree remove two
three="$(agent-worktree create three)"
printf 'three\n' > "$three/three.txt"; git -C "$three" add .; git -C "$three" commit -qm three
reject agent-worktree integrate three --check false
[ "$(git -C "$target" rev-parse HEAD)" = "$old" ] || fail 'failed check committed'
[ -f "$(git -C "$target" rev-parse --git-path MERGE_HEAD)" ] || fail 'failed check discarded pending merge'
reject agent-worktree integrate three
git -C "$target" merge --abort
reject agent-worktree integrate three --check 'printf changed >> shared.txt'
[ "$(git -C "$target" rev-parse HEAD)" = "$old" ] || fail 'mutating check committed'
git -C "$target" restore shared.txt
git -C "$target" merge --abort
agent-worktree integrate three --check 'test -f three.txt' >/dev/null
printf 'new\n' >> "$three/three.txt"; git -C "$three" commit -qam new
reject agent-worktree remove three
mkdir -p "$three/cache"; printf 'keep\n' > "$three/cache/file"
reject agent-worktree remove three --keep-branch
rm "$three/cache/file"; rmdir "$three/cache"
branch="$(git -C "$three" symbolic-ref --short HEAD)"
agent-worktree remove three --keep-branch >/dev/null
git show "${branch}:three.txt" | grep -qx new
ok 'conflicts and failed checks stay reviewable; unmerged and ignored data are preserved'

setup fleet
agent-fleet --worktree --no-say a=codex b=claude >/dev/null
agent-worktree list --json | jq -e 'length == 2 and (map(.base) | unique | length) == 1 and (map(.branch) | unique | length) == 2' >/dev/null
count="$(cat "$FAKE_STATE/next")"
reject agent-fleet --worktree good=codex bad=missing
reject agent-fleet --worktree dup=codex dup=codex
[ "$(cat "$FAKE_STATE/next")" = "$count" ] || fail 'invalid fleet partially spawned'
old_base="$(agent-worktree show a --json | jq -r '.base')"
agent-dismiss --all-spawned >/dev/null
git commit --allow-empty -qm 'caller advances'
agent-fleet --worktree --no-say a=codex b=claude >/dev/null
[ "$(agent-worktree show a --json | jq -r '.base')" = "$old_base" ] || fail 'fleet restart changed retained base'
other_repo="$scratch/other-repo"; mkdir -p "$other_repo"; git -C "$other_repo" init -q
git -C "$other_repo" commit --allow-empty -qm initial
(cd "$other_repo" && reject agent-worktree create a)
reject agent-worktree create '../escape'
ok 'fleet shares a pinned base, preflights specs and rejects cross-repo name reuse'

setup concurrent
mkdir -p "$AGENT_BUS_DIR/worktrees/locks/dead.record.lock"
printf '%s 2147483647 stale\n' "${HOSTNAME:-$(hostname)}" > "$AGENT_BUS_DIR/worktrees/locks/dead.record.lock/owner"
agent-worktree create dead >/dev/null
agent-worktree remove dead --keep-branch >/dev/null
agent-worktree create a > "$scratch/a-path" 2> "$scratch/a-err" & p1=$!
agent-worktree create b > "$scratch/b-path" 2> "$scratch/b-err" & p2=$!
wait "$p1"; wait "$p2"
agent-worktree list --json | jq -e '[.[] | select(.status != "removed")] | length == 2' >/dev/null
agent-worktree create same > "$scratch/same1" 2> "$scratch/same1-err" & p1=$!
agent-worktree create same > "$scratch/same2" 2> "$scratch/same2-err" & p2=$!
wait "$p1"; wait "$p2"
cmp "$scratch/same1" "$scratch/same2"
ok 'concurrent creation serializes Git operations and reuses a single checkout per name'

setup concurrent-spawn
agent-spawn --worktree --as codex --no-say same > "$scratch/spawn1" 2>&1 & p1=$!
agent-spawn --worktree --as codex --no-say same > "$scratch/spawn2" 2>&1 & p2=$!
if wait "$p1"; then r1=0; else r1=$?; fi
if wait "$p2"; then r2=0; else r2=$?; fi
[ $((r1 + r2)) -gt 0 ] && { [ "$r1" -eq 0 ] || [ "$r2" -eq 0 ]; } || fail 'concurrent duplicate spawns were not rejected'
[ "$(cat "$FAKE_STATE/next")" = 11 ] || fail 'duplicate spawn opened two panes'
printf '20\n21\n22\n23\n' >> "$FAKE_STATE/live"
CMUX_SURFACE_ID=s-20 agent-init --no-files twenty >/dev/null & p1=$!
CMUX_SURFACE_ID=s-21 agent-init --no-files twentyone >/dev/null & p2=$!
CMUX_SURFACE_ID=s-22 agent-init --no-files twentytwo >/dev/null & p3=$!
CMUX_SURFACE_ID=s-23 agent-init --no-files twentythree >/dev/null & p4=$!
wait "$p1"; wait "$p2"; wait "$p3"; wait "$p4"
jq -e '.agents | has("twenty") and has("twentyone") and has("twentytwo") and has("twentythree")' "$AGENT_BUS_DIR/agents.json" >/dev/null
ok 'duplicate spawns open one pane and concurrent registration preserves every worker'

setup repo-scope
unset AGENT_BUS_DIR
export AGENT_BUS_SCOPE=repo
agent-init --no-files --lead lead >/dev/null
mkdir -p nested
cd nested
agent-spawn --split --worktree --as codex --no-say scoped >/dev/null
path="$(agent-worktree path scoped)"
surface="$(jq -r '.agents.scoped' "$project/.agents/agents.json")"
jq -e --arg p "$path" --arg bus "$project/.agents" '.cwd == $p and .bus == $bus' "$FAKE_STATE/launch-$surface.json" >/dev/null
[ ! -e "$path/.agents/agents.json" ] || fail 'repo-scoped worker created its own bus'
ok 'repo scope from a subdirectory and split launch keep the original bus'
echo 'All worktree tests passed.'
