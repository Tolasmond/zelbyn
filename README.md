# gnrcrdr
Data-driven binary file reader written in [Odin](https://odin-lang.org/). File formats are described in a SQLite database (see `data/Gif89a.sql`).

## Building

Requires Odin `dev-2026-10` or newer. Build and run from the repository root:

```
odin build .
```

- **Windows:** links the bundled `sqlite3/sqlite3.lib` and produces `gnrcrdr.exe`.
- **Linux:** links the system SQLite (`libsqlite3`; on Arch the `sqlite` package, on Debian/Ubuntu `libsqlite3-dev`) and produces `gnrcrdr.bin`.

## Checks and tests

Run from the repository root. All of these must pass before committing:

```
odin check . -vet -strict-style
odin check . -vet -strict-style -debug
odin check tests -vet -strict-style -no-entry-point
odin test tests -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_LOG_LEVEL=warning
odin test tests -o:speed -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_LOG_LEVEL=warning
```

Debug builds (`odin build . -debug`) run under a tracking allocator and exit 1 if anything leaks or is freed twice.
