# gnrcrdr
Data-driven binary file reader written in [Odin](https://odin-lang.org/). File formats are described in [Kaitai Struct](https://kaitai.io/) `.ksy` files (a subset, see [Schemas](#schemas)) in `formats/`, or in a SQLite database (`data/Gif89aMetadata.sqlite3`), which the `.ksy` files are replacing.

## Building

Requires Odin `dev-2026-10` or newer. Build and run from the repository root:

```
odin build .
```

- **Windows:** links the bundled `sqlite3/sqlite3.lib` and produces `gnrcrdr.exe`.
- **Linux:** links the system SQLite (`libsqlite3`; on Arch the `sqlite` package, on Debian/Ubuntu `libsqlite3-dev`) and produces `gnrcrdr.bin`.

## Usage

```
gnrcrdr <schema> <file> [--dump tree|json] [--format N]
```

Decodes `<file>` with the schema and writes the decoded tree to stdout. A schema whose name ends in `.ksy` is a Kaitai Struct schema; any other is a SQLite database, from which `--format` picks the format (default `1`). For example:

```
./gnrcrdr.bin formats/gif89a.ksy data/855.gif
./gnrcrdr.bin formats/gif89a.ksy data/855.gif --dump json
./gnrcrdr.bin data/Gif89aMetadata.sqlite3 data/855.gif
```

`formats/gif89a.ksy` is the SQLite schema ported field for field, and gives the same output. Options may also be written `--format=N` and `--dump=json`. `--help` (or `-h`) prints usage.

### Output

`--dump tree` (the default) writes one line per decoded value: its path, ` = `, then the value. Fields are listed in schema order, and `[i]` is the index within each array. A set (such as `Logical Screen Descriptor`) gets no line of its own.

```
GIF89a[0].Signature[0] = "GIF"
GIF89a[0].Logical Screen Descriptor[0].Logical Screen Width[0] = 500
GIF89a[0].Global Color Table[0].Red[0] = 252
GIF89a[0].Blocks[0].Image[0].Table Based Image Data[0].Image Data[0].Data Sub-Block Values[0] = <254 bytes> 80 42 29 83 84 83 56 3c 83 7e 29 8a 8c 8b 8e 8d ...
```

Integers are decimal and strings are quoted. A blob shows its length and its first 16 bytes in hex, followed by `...` if it is longer.

An integer with packed bit fields is followed by one line for each of them, in the order of their lowest bit:

```
GIF89a[0].Logical Screen Descriptor[0].Logical Screen Descriptor Packed Fields[0] = 246
GIF89a[0].Logical Screen Descriptor[0].Size of Global Color Table[0] = 6
GIF89a[0].Logical Screen Descriptor[0].Sort Flag[0] = 0
GIF89a[0].Logical Screen Descriptor[0].Color Resolution[0] = 7
GIF89a[0].Logical Screen Descriptor[0].Global Color Table Flag[0] = 1
```

`--dump json` writes the same tree as compact JSON on one line. Each set instance is an object whose keys are its field names in schema order, each followed by its bit fields, and every field is an array:

```
{"GIF89a":[{"Signature":["GIF"],"Version":["89a"],"Logical Screen Descriptor":[{"Logical Screen Width":[500],...
```

Blobs are written in full as lowercase hex strings. NaN and infinite floats are written as `null`.

Because the path is on every line, the text dump works well with `grep`, for example `... data/BOB_89A.GIF | grep 'Comment'`.

### Errors and exit codes

Stdout carries only the decoded tree. Errors and usage messages go to stderr, and nothing is written to stdout if loading or decoding fails.

| Exit code | Meaning |
|---|---|
| 0 | Success, including `--help` |
| 1 | The format could not be loaded, the file could not be read or decoded, or the output could not be written |
| 2 | Usage error: a missing or extra argument, an unknown flag, a bad `--format` or `--dump` value, or `--format` with a `.ksy` schema |

`--dump` values are case-sensitive.

A `.ksy` schema that cannot be compiled is reported with its line and column, and the kind of problem: `Syntax`, `Unsupported` (valid YAML or Kaitai outside the supported subset) or `Invalid`:

```
error: formats/x.ksy:6:5: Unsupported: attribute a: if is not supported
```

Decoding checks every value against its field's `contents` and `valid` (in a SQLite schema, `MinValue`, `MaxValue` and `Pattern`). A value that does not pass stops the decode with `Not_Equal`, `Less_Than_Min`, `Greater_Than_Max` or `Not_Any_Of`, at the offset and path of that value. A file that is not a GIF fails on its signature:

```
error: Not_Equal at 0x00000000 in GIF89a[0].Signature[0]
```

## Schemas

`.ksy` schemas are read with gnrcrdr's own YAML parser, which accepts the YAML that `.ksy` files use and rejects anchors, aliases, tags, merge keys, complex keys, multi-document streams and duplicate keys. The compiler supports this subset of Kaitai Struct, and rejects everything else, naming the key and its location:

| Area | Supported |
|---|---|
| Top level | `meta`, `seq`, `types`, `enums`, `doc`, `doc-ref` |
| `meta` | `id`, `endian`, `bit-endian`, `encoding`; `title`, `file-extension`, `xref`, `license` (ignored) |
| Attributes | `id`, `type`, `size`, `contents`, `valid` (a constant, or `eq`, `min`/`max`, `any-of`), `repeat: expr` with `repeat-expr`, `encoding`, `doc`, `doc-ref` |
| Types | `u1`–`u8`, `s1`–`s8`, `f4`, `f8` (with `le`/`be` or `meta: endian`), `str` with `size` (ASCII or UTF-8, kept as bytes, NULs included), byte arrays, user types (not recursive) |
| Expressions | integer and boolean operators, `?:`, field references, `_parent`, `_root`, `_io.pos`, `_io.size`, `_io.eof`, `.size`, `_index`, enum constants (`kinds::two`) |

A `repeat-expr` that is not a literal is supported only on a user type. Not supported yet: `if`, `enum` on an attribute, `repeat: eos` and `until`, `terminator`, `strz`, `size-eos`, bit types (`b1`–`b64`), `switch-on`, `instances`, `size` on a user type, and `valid` constants other than integer and string literals.

Keys starting with `-` are extensions; the official Kaitai tools ignore them, and so does gnrcrdr when it does not know them. gnrcrdr's extensions keep the SQLite schema's dumps while it is ported:

| Extension | Meaning | In standard Kaitai |
|---|---|---|
| `-orig-id: Name` | The name shown in the dump and in error paths, instead of the `id` (on `meta`, the root's name). Expressions still use the `id`. | No equivalent; the dump uses the `id`. |
| `-peek: [b, ...]` | On a user-type attribute: read it once if the input at the current position starts with these bytes, else not at all. Nothing is consumed by the test. | `if:` on an `instances` entry that reads the bytes at `pos: _io.pos`. |
| `-while-peek: [b]` | On a user-type attribute: read instances while the next byte is `b`, which is not consumed. Stops at the end of the input. | `repeat: until` over a type that reads the byte, or an `instances` peek in each element. |
| `-until-peek: [b]` | As `-while-peek`, but until the next byte is `b`, which is not consumed; reaching the end of the input first is an error. | `repeat: until`, which consumes the terminating element and keeps it. |
| `-bits: [{id, -orig-id, low, high}, ...]` | On an integer attribute: unsigned subfields of bits `low` to `high` (0 is the least significant), dumped after the integer in order of their low bit. | `value:` instances that mask and shift the integer, or `b1`–`b64` fields in a user type. |

Each instance read by `-while-peek` or `-until-peek` must consume input. The byte lists take the same forms as `contents`; `-while-peek` and `-until-peek` take one byte.

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

### Golden dumps

`tests/golden/` holds the `--dump tree` and `--dump json` output of every sample in `data/`, and the tests compare each dump, from the SQLite schema and from `formats/gif89a.ksy`, with it byte for byte. When a change to the decoder or the dump is meant to change the output, re-record the files (from the SQLite schema) and review the diff before committing it:

```
odin test tests -define:GOLDEN_RECORD=true
git diff --stat tests/golden
```

### YAML corpus check

`gnrcrdr/yaml` parses the subset of YAML that `.ksy` files use. `tools/yaml_corpus/compare.py` checks it against libyaml on every `.ksy` file in a directory, normally a clone of [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) kept outside this repository. It needs PyYAML built with libyaml (on Arch, `python-yaml`):

```
git clone --depth 1 https://github.com/kaitai-io/kaitai_struct_formats ../kaitai_struct_formats
python3 tools/yaml_corpus/compare.py ../kaitai_struct_formats
```

Every file must give the same node tree from both parsers (kinds, scalar styles and text, and every line and column), or be rejected by gnrcrdr as outside the subset (anchors, aliases, tags, merge keys, complex keys, directives, multi-document streams, duplicate keys), or be rejected by both. The script exits 1 if any file differs. Run it when the parser changes.
