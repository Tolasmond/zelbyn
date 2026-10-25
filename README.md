# zelbyn

zelbyn is a data-driven binary file reader written in [Odin](https://odin-lang.org/). It decodes a file with a [Kaitai Struct](https://kaitai.io/) `.ksy` schema and writes the decoded tree to stdout, as a text dump or as JSON, optionally with the offset of every value in the file.

The official Kaitai Struct compiler generates a parser for each format, in many languages but not Odin. zelbyn reads the schema at run time instead and compiles it into a checked plan, so a new format needs no generated code and no rebuild, and a schema error names its file, line and column. For a program that decodes a format itself, `zelbyn gen` writes the plan as Odin code: a package with a struct for each type of the schema and a `read` that decodes bytes into them as zelbyn does.

## Quick start

Binaries for Linux and Windows (x86-64) are on the [releases page](https://github.com/Tolasmond/zelbyn/releases). To build it, with Odin `dev-2026-10` or newer:

```
odin build . -out:build/zelbyn
git clone https://github.com/kaitai-io/kaitai_struct_formats ../kaitai_struct_formats
git clone https://github.com/kaitai-io/kaitai_struct_samples ../kaitai_struct_samples
build/zelbyn ../kaitai_struct_formats/image/png.ksy ../kaitai_struct_samples/image/png/atch-plain.png
build/zelbyn ../kaitai_struct_formats/image/png.ksy ../kaitai_struct_samples/image/png/atch-plain.png --dump json
```

To generate a package that decodes PNG files, `build/zelbyn gen ../kaitai_struct_formats/image/png.ksy --out png --import-path ../kaitai_struct_formats`; [doc/usage.md](doc/usage.md#generating-code) says how to build and use it.

On Windows the build is `build\zelbyn.exe`. It has no other dependencies. The repository holds no schemas or sample files of real formats, so the examples use those of the Kaitai Project's [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) and [kaitai_struct_samples](https://github.com/kaitai-io/kaitai_struct_samples).

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

All 190 schemas in [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) compile, at the commit `tools/ksy_corpus/expected.txt` records. Separately, decodes are compared with the official runtime's (0.11), value for value and offset for offset, on the 43 samples of the 18 formats that have samples in [kaitai_struct_samples](https://github.com/kaitai-io/kaitai_struct_samples), at the commit [doc/development.md](doc/development.md#corpus-check) gives. 41 of those agree. Two fail: a malformed one, in both decoders, and one whose schema tests a field it never read, which the JavaScript runtime takes as 0 and zelbyn, like the Python and Java runtimes, rejects. The code that `zelbyn gen` writes builds for all 190 schemas, decodes those 43 samples as zelbyn does, the two that fail failing alike, and gives zelbyn's result for every input zelbyn's own tests decode. Development is on Linux; CI builds and tests on Linux and Windows, in release and debug builds.

## Documentation

- [Usage](doc/usage.md): building, the command line, the output, errors and exit codes, generating code, and the supported subset of Kaitai Struct.
- [Development](doc/development.md): the checks a change must pass, the benchmark, and the comparisons with the official runtime, with libyaml and of generated code.
- [Architecture](doc/arch.md): how the implementation works, and why.

## License

zelbyn is under the MIT License; see [LICENSE](LICENSE). It reads the [Kaitai Struct](https://kaitai.io/) language of the Kaitai Project, with which it is not affiliated, and adapts code of its C++ runtime; [THIRD_PARTY.md](THIRD_PARTY.md) gives the notices.
