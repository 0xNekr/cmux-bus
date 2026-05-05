# Tests

Run the smoke suite from the repository root:

```sh
./tests/run.sh
```

The suite is intentionally plain Bash: no Bats, Python, or Node dependency.
It creates temporary workspaces, injects a fake `cmux` into `PATH`, and leaves
the real user home and cmux socket untouched.

Covered areas:

- `agent-init` direct and via symlink, including protocol/template sync
- `install.sh` symlinking all commands
- `agent-send` ref validation, paths/status parsing, peer signaling, multiline
  bodies, invalid recipients/types/statuses, stale recipients, `to=user`
  behavior, and concurrent writes
- `agent-done` signaling and unknown ids
- `agent-cancel` and `agent-resume` recovery events and rejection paths
- `agent-inbox` empty, stale, and stuck cases
- `agent-doctor` ok summaries, duplicate ids, orphan refs, and malformed JSONL

The fake `cmux` implements only the contract the scripts need:

- `cmux --id-format both surface-health`
- `cmux send`
- `cmux send-key`

Set `CMUX_LOG` inside a test to capture fake `send` / `send-key` calls.
