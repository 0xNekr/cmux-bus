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
  bodies, and concurrent writes
- `agent-done` signaling
- `agent-cancel` and `agent-resume` recovery events
- `agent-inbox` empty, stale, and stuck cases

The fake `cmux` implements only the contract the scripts need:

- `cmux --id-format both surface-health`
- `cmux send`
- `cmux send-key`

Set `CMUX_LOG` inside a test to capture fake `send` / `send-key` calls.
