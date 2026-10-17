# gnrcrdr
Data-driven binary file reader written in [Odin](https://odin-lang.org/). File formats are described in a SQLite database (see `data/Gif89a.sql`).

## Building

Requires Odin `dev-2026-10` or newer. Build and run from the repository root:

```
odin build .
```

- **Windows:** links the bundled `sqlite3/sqlite3.lib` and produces `gnrcrdr.exe`.
- **Linux:** links the system SQLite (`libsqlite3`; on Arch the `sqlite` package, on Debian/Ubuntu `libsqlite3-dev`) and produces `gnrcrdr.bin`.
