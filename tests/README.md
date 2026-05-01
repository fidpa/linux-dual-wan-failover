# Tests

Unit tests use [bats-core](https://github.com/bats-core/bats-core).
Each test sources the relevant library and calls a function in
isolation; system commands like `ip`, `nmcli`, `ping` are intercepted
by mocks under `tests/mocks/`.

## Layout

```
tests/
├── mocks/        # PATH-overriding stubs for system commands
├── fixtures/     # config and JSON snapshots for tests
├── unit/         # bats test files
└── helpers.bash  # shared setup/teardown helpers
```

## Running

```bash
# All unit tests:
bats tests/unit/

# A single file:
bats tests/unit/test_quota.bats

# With verbose output:
bats --print-output-on-failure tests/unit/
```

## Conventions

- One bats file per source-file area (`test_quota.bats` covers the
  quota functions in `performance.sh`, etc.).
- Each test starts by calling `setup_test_env` from `helpers.bash`.
- Use `BATS_TMPDIR` for any files the function under test writes —
  never write to real `/var/lib/...` paths.
- Mocks under `tests/mocks/` are real Bash scripts; PATH is set to
  prefer them in `helpers.bash::setup_test_env`.
