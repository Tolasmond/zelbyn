# zelbyn

zelbyn is a data-driven binary file reader written in [Odin](https://odin-lang.org/). It decodes a file with a [Kaitai Struct](https://kaitai.io/) `.ksy` schema and writes the decoded tree to stdout, as a text dump or as JSON, optionally with the offset of every value in the file.

The official Kaitai Struct compiler generates a parser for each format, in many languages but not Odin. zelbyn reads the schema at run time instead and compiles it into a checked plan, so a new format needs no generated code and no rebuild, and a schema error names its file, line and column.

## Quick start

With Odin `dev-2026-10` or newer:

```
odin build . -out:build/zelbyn
build/zelbyn formats/gif.ksy data/855.gif
build/zelbyn formats/gif.ksy data/855.gif --dump json
```

On Windows the build is `build\zelbyn.exe`. It has no other dependencies.

## What a schema can use

| Area | Supported |
|---|---|
| Values | integers, floats and bit types in either byte order, strings in ten encodings, byte arrays, `contents` and `valid` checks |
| Structure | user types and substreams, `switch-on` types and byte orders, repeats by count, to the end of the stream or until a condition, types that contain themselves |
| Schemas | imports, types and enums named by path, `meta` per type |
| Expressions | the operators, methods, casts and sizes of Kaitai's expression language, enum constants, `_parent`, `_root`, `_io` and `_index` |
| Instances | value instances, instances read at a position, in any stream, and conditional ones |
| Params | on any type, and on the top-level type from the command line |
| Processing | `process: zlib` |

Not yet: other processes (`xor`, `rotate`, custom ones), other encodings (such as `Shift_JIS`), writing files, and the other gaps listed in [doc/usage.md](doc/usage.md#schemas).

## How it is checked

All 190 schemas in [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) compile. Decodes are compared with the official runtime's (0.11), value for value and offset for offset, on the GIF samples in `data/` and on the samples of all 18 formats in [kaitai_struct_samples](https://github.com/kaitai-io/kaitai_struct_samples). Two samples fail: a malformed one, in both decoders, and one whose schema tests a field it never read, which the JavaScript runtime takes as 0 and zelbyn, like the Python and Java runtimes, rejects. Development is on Linux; the Windows build is untested.

## Documentation

- [Usage](doc/usage.md): building, the command line, the output, errors and exit codes, and the supported subset of Kaitai Struct.
- [Development](doc/development.md): the checks a change must pass, the golden dumps, the benchmark, and the comparisons with the official runtime and with libyaml.
- [Architecture](doc/arch.md): how the implementation works, and why.
