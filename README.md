# gnrcrdr
Data-driven binary file reader written in [Odin](https://odin-lang.org/). File formats are described in [Kaitai Struct](https://kaitai.io/) `.ksy` files (a subset, see [Schemas](#schemas)) in `formats/`.

## Building

Requires Odin `dev-2026-10` or newer. Build and run from the repository root:

```
odin build .
```

This produces `gnrcrdr.exe` on Windows and `gnrcrdr.bin` on Linux. There are no other dependencies.

## Usage

```
gnrcrdr <schema.ksy> <file> [--dump tree|json] [--offsets] [--import-path dirs]
```

Decodes `<file>` with the Kaitai Struct schema and writes the decoded tree to stdout. For example:

```
./gnrcrdr.bin formats/gif.ksy data/855.gif
./gnrcrdr.bin formats/gif.ksy data/855.gif --dump json
./gnrcrdr.bin formats/gif89a.ksy data/855.gif
```

`formats/gif.ksy` is `gif.ksy` from [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats), unchanged (CC0-1.0), and decodes the samples as the official Kaitai Struct runtime does (see [Kaitai runtime check](#kaitai-runtime-check)). `formats/gif89a.ksy` is a field-for-field port of the SQLite schema gnrcrdr used before `.ksy`, written with gnrcrdr's extensions, and gives the same output as that schema did. Options may also be written `--dump=json`. `--import-path` lists the directories that a schema's absolute imports (`/common/x`) are found in, separated by `:` (`;` on Windows), as the official compiler's `-I` does. `--help` (or `-h`) prints usage.

### Output

`--dump tree` (the default) writes one line per decoded value: its path, ` = `, then the value. Fields are listed in schema order, and `[i]` is the index within each array. A set (such as `logical_screen_descriptor`) gets no line of its own, and a field that was not read (its `if` was false, or no `switch-on` case matched) gets none either.

```
gif[0].hdr[0].version[0] = "89a"
gif[0].logical_screen_descriptor[0].screen_width[0] = 500
gif[0].global_color_table[0].entries[0].red[0] = 252
gif[0].blocks[2].body[0].image_data[0].subblocks[0].entries[0].bytes[0] = <254 bytes> 80 42 29 83 84 83 56 3c 83 7e 29 8a 8c 8b 8e 8d ...
```

With `--offsets`, each line ends with ` @0x` and the offset in the file, in hex, where the value was read:

```
gif[0].logical_screen_descriptor[0].screen_width[0] = 500 @0x6
gif[0].blocks[2].body[0].image_data[0].subblocks[0].entries[0].bytes[0] = <254 bytes> 80 42 29 83 84 83 56 3c 83 7e 29 8a 8c 8b 8e 8d ... @0x1B4
```

The offset is the one Kaitai Struct's debug mode records, which the Web IDE shows: the stream's position when the value starts to be read. A bit type that only uses bits left over from the value before it starts where that value ended. `--offsets` applies only to `--dump tree`. To give the offsets, the decoder records the span of every value, so decoding takes about 30% longer, and the tree about 45% more memory.

Integers are decimal, a `b1` field is `true` or `false`, and strings are quoted. A blob shows its length and its first 16 bytes in hex, followed by `...` if it is longer. A field with an `enum` shows its integer. Value instances (such as `has_color_table`) are not read from the file, so they are not shown. Parse instances (`instances` with `pos`) are read, and shown after the fields of their type, in the order of `instances`.

In a schema with the `-bits` extension, such as `formats/gif89a.ksy`, an integer with packed bit fields is followed by one line for each of them, in the order of their lowest bit:

```
GIF89a[0].Logical Screen Descriptor[0].Logical Screen Descriptor Packed Fields[0] = 246
GIF89a[0].Logical Screen Descriptor[0].Size of Global Color Table[0] = 6
GIF89a[0].Logical Screen Descriptor[0].Sort Flag[0] = 0
GIF89a[0].Logical Screen Descriptor[0].Color Resolution[0] = 7
GIF89a[0].Logical Screen Descriptor[0].Global Color Table Flag[0] = 1
```

`--dump json` writes the same tree as compact JSON on one line. Each set instance is an object whose keys are its field names in schema order, each followed by its bit fields, then its parse instances, and every field is an array:

```
{"gif":[{"hdr":[{"magic":["474946"],"version":["89a"]}],"logical_screen_descriptor":[{"screen_width":[500],...
```

Blobs are written in full as lowercase hex strings. Strings are escaped as JSON requires, and each byte that is not part of valid UTF-8 is written `\u00NN`, the character of the same value, so the output is always valid JSON; a JSON reader cannot tell such a byte from that character. A `b1` field is `true` or `false`, and NaN and infinite floats are written as `null`.

A field that was not read is an empty array.

Because the path is on every line, the text dump works well with `grep`, for example `... data/BOB_89A.GIF | grep 'subblocks'`.

### Errors and exit codes

Stdout carries only the decoded tree. Errors and usage messages go to stderr, and nothing is written to stdout if loading or decoding fails.

| Exit code | Meaning |
|---|---|
| 0 | Success, including `--help` |
| 1 | The format could not be loaded, the file could not be read or decoded, or the output could not be written |
| 2 | Usage error: a missing or extra argument, an unknown flag, or a bad `--dump` value |

`--dump` values are case-sensitive.

A `.ksy` schema that cannot be compiled is reported with its file (the schema, or one it imports), line and column, and the kind of problem: `Syntax`, `Unsupported` (valid YAML or Kaitai outside the supported subset) or `Invalid`:

```
error: formats/x.ksy:6:5: Unsupported: attribute a: process is not supported
```

Decoding checks every value against its field's `contents` and `valid`. A value that does not pass stops the decode with `Not_Equal`, `Less_Than_Min`, `Greater_Than_Max` or `Not_Any_Of`, at the offset and path of that value. A file that is not a GIF fails on its signature:

```
error: Not_Equal at 0x00000000 in gif[0].hdr[0].magic[0]
```

## Schemas

`.ksy` schemas are read with gnrcrdr's own YAML parser, which accepts the YAML that `.ksy` files use and rejects anchors, aliases, tags, merge keys, complex keys, multi-document streams and duplicate keys. The compiler supports this subset of Kaitai Struct, and rejects everything else, naming the key and its location:

| Area | Supported |
|---|---|
| Top level | `meta`, `params` (in an imported schema), `seq`, `types`, `instances`, `enums` (each value a name, or a mapping of `id`, `doc` and `doc-ref`), `doc`, `doc-ref` |
| `meta` | `id`, `endian`, `bit-endian`, `encoding`, `ks-version` (0.11 or older, the Kaitai version gnrcrdr follows), `imports`; `title`, `application`, `file-extension`, `xref`, `license`, `tags` (ignored) |
| Attributes | `id`, `type`, `size`, `size-eos`, `terminator` (with `consume`, `include`, `eos-error`), `pad-right`, `contents`, `if`, `enum`, `valid` (a constant, or `eq`, `min`/`max`, `any-of`), `repeat` (`expr` with `repeat-expr`, `eos`, `until` with `repeat-until`), `encoding`, `doc`, `doc-ref` |
| Types | `u1`–`u8`, `s1`–`s8`, `f4`, `f8` (with `le`/`be` or `meta: endian`), `b1`–`b64` (with `le`/`be` or `meta: bit-endian`, else big-endian; `b1` is a boolean, unless it has an `enum`), `str` with `size`, `size-eos` or `terminator`, and `strz` (ASCII or UTF-8, kept as bytes, NULs included within a `size`), byte arrays, user types (not recursive; with `size`, `size-eos` or `terminator`, read from a substream of those bytes; with arguments, `t(a, b)`, when they have `params`), `switch-on` with `cases` whose types are user types, including the `_` default case |
| Params | `id`, `type` (an integer type, `bool` or `bytes`), `enum` (on an integer), `doc`, `doc-ref` |
| Instances | value instances (`value:`, with `if` and `enum`), over the fields and other value instances of their own type. Expressions anywhere can refer to them; they are evaluated each time, and not dumped. One whose `if` is false has no value, and an expression that refers to it fails, as for a field with none. Parse instances (`pos:`), with the keys of an attribute other than `id`, and `io`: the stream to read at `pos` in, `_io` or the `_io` of a set instance (`_root._io`, `_parent._io`, `header._io`), or a `?:` of those. A set field's stream can be used once the field is read; one that was not read is absent |
| Expressions | integer and boolean operators, `?:`, field references, `_parent`, `_root`, `_io.pos`, `_io.size`, `_io.eof` (of the substream, inside one; in a parse instance with `io`, still of its type's stream), `.size`, `_index`, `_` in `repeat-until`, enum constants (`kinds::two`) |

With a `size`, the bytes are read, `pad-right` is removed from their end, and they are cut at the `terminator`, if one is given. Without one, they run up to the `terminator`; `include` keeps it in the value, and `consume: false` leaves the reader at it, as in the C++ and Python runtimes (the JavaScript runtime moves one byte further when `include` is set). `consume` and `eos-error` do not apply with a `size`, nor `pad-right` without one.

A bit type reads on from the bits left over in its stream, in its bit order, and then from as many more bytes as it needs. Bits are left over until something reads them: as in Kaitai, an attribute that follows a bit type, and is not one, starts at the next byte, but an attribute after a user type does not. So the bit type after a user type that ends with bits left over reads those bits, as Kaitai's runtimes do. `_io.eof` is true once every byte and every bit left over is read. A substream starts at its first byte, and so does a parse instance, which in Kaitai's runtimes reads on from whatever bits are left over when it is first used.

A parse instance is read at `pos` in the stream of its type, which does not move, the first time an expression refers to it, as in Kaitai. Any that no expression has read are read once the fields of their type are, so every parse instance is in the decoded tree; an error in one fails the decode, even if nothing uses it. A `pos` outside the stream is `Offset_Out_Of_Range`.

Each entry of `imports` names a schema file without its `.ksy`: relative to the directory of the schema that imports it, or, when it starts with `/`, in the first `--import-path` directory that has it. The top-level type of an imported schema is used by its `meta` `id`, and its own `meta` (`endian`, `encoding`) applies inside it. As in Kaitai, it is the `_root` of its own types and has no `_parent`. A schema imported more than once is read once.

A type with `params` is given one argument for each, `t(a, b)`, in `type` or in a `switch-on` case. Each argument is an expression of the param's type, evaluated where each instance is read: as in Kaitai, in the stream of the field, after the bytes of a substream, and for a parse instance after it moves to `pos`. Expressions in the type refer to its params by their `id`, and params are not dumped. An integer param holds the argument's value as it is, whatever its integer type, as in the JavaScript runtime, and one with an `enum` takes any integer, where the official compiler requires a value of the enum. The type of the schema itself cannot have params, since nothing would give their arguments.

A field read once whose `switch-on` matches no case, without a `_` case, is not read, as in Kaitai; a repeated `switch-on` needs a `_` case. Expressions cannot refer to a `switch-on` field. Each element read by `repeat: eos` must consume input, and so must each element of `repeat: until` but the last.

Not supported yet: instances without `pos` or `value`, params of other types (`str`, user types, `struct`, `io`, `any`), a type of another type (`a::b`, such as a type declared in an imported schema), attributes without an `id`, `size`, `size-eos` or `terminator` on a `switch-on` field, cases that are not user types, an `enum` of another type (`a::b`), and `valid` constants other than integer and string literals.

Keys starting with `-` are extensions. The official Kaitai tools ignore them, and gnrcrdr ignores the ones it does not know, as well as `-orig-id` on a type. gnrcrdr's own extensions let `formats/gif89a.ksy` give the same dumps as the SQLite schema it was ported from:

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

`tests/golden/` holds the `--dump tree` and `--dump json` output of every sample in `data/` from `formats/gif.ksy`, and `tests/golden/gif89a/` that from `formats/gif89a.ksy`. The `gif89a/` dumps were recorded from the SQLite schema, which the port reproduces exactly. The tests compare each dump with them byte for byte. When a change to the decoder or the dump is meant to change the output, re-record the files from both schemas and review the diff before committing it:

```
odin test tests -define:GOLDEN_RECORD=true
git diff --stat tests/golden
```

### Benchmark

gnrcrdr is measured the way a terminal tool runs: cold, in a fresh process for every measurement, with nothing shared between runs (decision record §10). `tools/bench/bench.py` builds gnrcrdr and the one-shot program in `tools/bench` with `-o:speed`, then runs them 200 times per sample, interleaving samples and programs:

```
python3 tools/bench/bench.py
```

For each file it prints medians of:
- the input size, the tree size (the bytes the tree's arena handed out), and the page faults taken during the decode (not counted on Windows);
- the time to compile the schema, read the file, decode it and write the JSON dump to memory, each timed inside one process;
- the whole-process time of `gnrcrdr <schema> <file> --dump json`, with its output discarded.

It also prints the time to start a process that exits at once, which is part of every whole-process time. Options: `--runs N`, `--schema S` (default `formats/gif.ksy`), `--spans` (decode with spans, and time the CLI with `--offsets` instead of `--dump json`), and the files (default the samples in `data/`).

Run it before and after a change meant to make decoding faster or the tree smaller, in the same session, and give both sets of figures in the commit message. A sampling profiler may loop over one file to show where time goes, but its percentages leave out the cost of touching memory for the first time, so the figures come from this benchmark.

#### Kaitai Struct C++ reference

With `--cpp`, the benchmark also runs the official Kaitai Struct C++ runtime, with the parser the official compiler generates from the same schema. It prints the C++ decode time and page faults, the ratio of gnrcrdr's decode time to the C++ one, and the C++ whole-process time (reading and decoding, with no output). Build the reference once. It needs Node.js, PyYAML, a C++11 compiler (`$CXX`, default `g++`) and a clone of the runtime at tag 0.11, kept outside this repository:

```
npm ci --prefix tools/kaitai_compare
git clone --depth 1 --branch 0.11 https://github.com/kaitai-io/kaitai_struct_cpp_stl_runtime ../kaitai_struct_cpp_stl_runtime
python3 tools/bench/cpp/build.py ../kaitai_struct_cpp_stl_runtime
python3 tools/bench/bench.py --cpp tools/bench/cpp/build/oneshot_cpp
```

The generated parser and the binary go to `tools/bench/cpp/build/`, which is not committed. The C++ decode builds a `kaitai::kstream` on the file's bytes and parses it. Strings are kept as bytes, as gnrcrdr keeps them, and on Linux libstdc++ is linked statically. To benchmark another schema, rebuild the reference with `--schema`.

### Kaitai runtime check

`tools/kaitai_compare/compare.py` decodes files with a `.ksy` schema both in gnrcrdr and with the official Kaitai Struct compiler and JavaScript runtime, and compares the results value by value. It needs Node.js and PyYAML, and the compiler and runtime, pinned in `tools/kaitai_compare/package.json`:

```
npm ci --prefix tools/kaitai_compare
python3 tools/kaitai_compare/compare.py formats/gif.ksy data/*.gif data/*.GIF
python3 tools/kaitai_compare/compare.py --import-path ../kaitai_struct_formats ../kaitai_struct_formats/image/pcx_dcx.ksy file.dcx
python3 tools/kaitai_compare/compare.py --offsets formats/gif.ksy data/*.gif data/*.GIF
```

Both decodes are brought to one shape, every field an array of its values, and compared field by field. Parse instances are compared as fields; fields with no values are left out on both sides, as are value instances and params. Names are compared by their ids, so gnrcrdr's `-orig-id` names are mapped back to them, and integers beyond 2^53, which the JavaScript runtime holds as doubles, are compared as doubles. The script reads the schemas the schema imports, and gives them to both decoders. With `--offsets` it compares offsets instead of values: those of gnrcrdr's `--offsets` dump, and those the runtime records in debug mode, for every value that is not a set instance. The script exits 1 if any file differs or fails to decode. Run it when the decoder, the `.ksy` compiler or `formats/gif.ksy` changes.

### Corpus check

`tools/ksy_corpus/check.py` compiles every `.ksy` file in a clone of [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats), kept outside this repository, and compares each file's result, compiled or its first error, with the record in `tools/ksy_corpus/expected.txt`. With `--samples` and a clone of [kaitai_struct_samples](https://github.com/kaitai-io/kaitai_struct_samples), it also runs `tools/kaitai_compare/compare.py`, on values and on offsets, for every format that compiles and has samples:

```
git clone https://github.com/kaitai-io/kaitai_struct_formats ../kaitai_struct_formats
git -C ../kaitai_struct_formats checkout f38fd7de89aa6cc171624ba08a0647e06e2ade47
git clone --depth 1 https://github.com/kaitai-io/kaitai_struct_samples ../kaitai_struct_samples
python3 tools/ksy_corpus/check.py --samples ../kaitai_struct_samples ../kaitai_struct_formats
```

The record names the commit of kaitai_struct_formats it was made at, and the clone must be at it. The script exits 1 if any file differs from the record, a file that no longer compiles, now compiles, or fails with another first error, or if any sample differs from the official runtime's decode. Run it when the `.ksy` compiler changes. When a change is meant to change the results, check the differences and run it again with `--record`, which rewrites the record; its diff then shows what the change did to the corpus.

### YAML corpus check

`gnrcrdr/yaml` parses the subset of YAML that `.ksy` files use. `tools/yaml_corpus/compare.py` checks it against libyaml on every `.ksy` file in a directory, normally a clone of [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) kept outside this repository. It needs PyYAML built with libyaml (on Arch, `python-yaml`):

```
git clone --depth 1 https://github.com/kaitai-io/kaitai_struct_formats ../kaitai_struct_formats
python3 tools/yaml_corpus/compare.py ../kaitai_struct_formats
```

Every file must give the same node tree from both parsers (kinds, scalar styles and text, and every line and column), or be rejected by gnrcrdr as outside the subset (anchors, aliases, tags, merge keys, complex keys, directives, multi-document streams, duplicate keys), or be rejected by both. The script exits 1 if any file differs. Run it when the parser changes.
