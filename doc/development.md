# Developing zelbyn

The checks a change must pass, the golden dumps, the benchmark, and the tools that compare zelbyn with the official Kaitai Struct runtime and with libyaml. Commands are run from the repository root. The design is described in [arch.md](arch.md).

## Checks and tests

All of these must pass before committing:

```
odin check . -vet -strict-style
odin check . -vet -strict-style -debug
odin check tests -vet -strict-style -no-entry-point
odin test tests -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_LOG_LEVEL=warning
odin test tests -o:speed -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_LOG_LEVEL=warning
odin test tests -debug -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_LOG_LEVEL=warning
odin check tools/bench -vet -strict-style
odin check tools/ksy_corpus -vet -strict-style
odin check tools/yaml_corpus -vet -strict-style
```

`tools/check.py` runs them all, each whatever the ones before it give, and ends with a summary; it exits 1 if any failed. It builds the tests in a temporary directory. The checks are pinned to Odin `dev-2026-10` (commit `84bc3fc`), and the script warns when another is on the `PATH`.

```
python3 tools/check.py
```

The checks that need what the repository does not hold run only when asked: `--formats ../kaitai_struct_formats` runs the corpus check, and with it `--samples ../kaitai_struct_samples` the sample comparison and `--yaml-corpus` the YAML corpus check (each below, with the clones and tools it needs, and the commits the clones must be at), and `--compare-tests` the tests of `tools/kaitai_compare`. Their results are reported as they are: the sample comparison fails on the two samples that "Corpus check" names, so a run with `--samples` exits 1.

```
python3 tools/check.py --formats ../kaitai_struct_formats --samples ../kaitai_struct_samples --yaml-corpus --compare-tests
```

`.github/workflows/check.yml` runs `tools/check.py` on every push to `main` and every pull request, on Linux and on Windows, with the Odin release it is pinned to, checked against its SHA-256. The debug build of the tests uses the most stack, and on Windows checks the stack limits against the 1 MB stack they are sized for (arch.md §7.5). The optional checks are not run there.

Debug builds (`odin build . -debug -out:build/zelbyn`) run under a tracking allocator and exit 1 if anything leaks or is freed twice.

## Golden dumps

`tests/golden/` holds the `--dump tree` and `--dump json` output of every sample in `data/` from `formats/gif.ksy`, and `tests/golden/gif89a/` that from `formats/gif89a.ksy`. The `gif89a/` dumps were recorded from the SQLite schema, which the port reproduces exactly. The tests compare each dump with them byte for byte. When a change to the decoder or the dump is meant to change the output, re-record the files from both schemas and review the diff before committing it:

```
odin test tests -define:GOLDEN_RECORD=true
git diff --stat tests/golden
```

## Benchmark

zelbyn is measured the way a terminal tool runs: cold, in a fresh process for every measurement, with nothing shared between runs. `tools/bench/bench.py` builds zelbyn and the one-shot program in `tools/bench` with `-o:speed`, then runs them 200 times per sample, interleaving samples and programs:

```
python3 tools/bench/bench.py
```

For each file it prints medians of:
- the input size, the tree size (the bytes the tree's arena handed out), and the page faults taken during the decode;
- the time to compile the schema, read the file, decode it and write the JSON dump to memory, each timed inside one process;
- the whole-process time of `zelbyn <schema> <file> --dump json`, with its output discarded.

It also prints the time to start a process that exits at once, which is part of every whole-process time. Options: `--runs N`, `--schema S` (default `formats/gif.ksy`), `--spans` (decode with spans, and time the CLI with `--offsets` instead of `--dump json`), and the files (default the samples in `data/`).

Run it before and after a change meant to make decoding faster or the tree smaller, in the same session, and give both sets of figures in the commit message. A sampling profiler may loop over one file to show where time goes, but its percentages leave out the cost of touching memory for the first time, so the figures come from this benchmark.

### Kaitai Struct C++ reference

With `--cpp`, the benchmark also runs the official Kaitai Struct C++ runtime, with the parser the official compiler generates from the same schema. It prints the C++ decode time and page faults, the ratio of zelbyn's decode time to the C++ one, and the C++ whole-process time (reading and decoding, with no output). Build the reference once. It needs Node.js, PyYAML, a C++11 compiler (`$CXX`, default `g++`) and a clone of the runtime at tag 0.11, kept outside this repository:

```
npm ci --prefix tools/kaitai_compare
git clone --depth 1 --branch 0.11 https://github.com/kaitai-io/kaitai_struct_cpp_stl_runtime ../kaitai_struct_cpp_stl_runtime
python3 tools/bench/cpp/build.py ../kaitai_struct_cpp_stl_runtime
python3 tools/bench/bench.py --cpp tools/bench/cpp/build/oneshot_cpp
```

The generated parser and the binary go to `tools/bench/cpp/build/`, which is not committed. The C++ decode builds a `kaitai::kstream` on the file's bytes and parses it. Strings are kept as bytes, as zelbyn keeps them, and on Linux libstdc++ is linked statically. To benchmark another schema, rebuild the reference with `--schema`.

## Kaitai runtime check

`tools/kaitai_compare/compare.py` decodes files with a `.ksy` schema both in zelbyn and with the official Kaitai Struct compiler and JavaScript runtime, and compares the results value by value. It needs Node.js and PyYAML, and the compiler and runtime, pinned in `tools/kaitai_compare/package.json`:

```
npm ci --prefix tools/kaitai_compare
python3 tools/kaitai_compare/compare.py formats/gif.ksy data/*.gif data/*.GIF
python3 tools/kaitai_compare/compare.py --import-path ../kaitai_struct_formats ../kaitai_struct_formats/image/pcx_dcx.ksy file.dcx
python3 tools/kaitai_compare/compare.py --offsets formats/gif.ksy data/*.gif data/*.GIF
python3 tools/kaitai_compare/compare.py --param num_digits=6 --param bits_per_digit=4 --param is_le=false ../kaitai_struct_formats/common/bcd.ksy number.bin
```

A `--param` of a user type is given to the runtime as an instance of the type that its constructor makes from the bytes.

Both decodes are brought to one shape, every field an array of its values, and compared field by field. Parse instances are compared as fields; fields with no values are left out on both sides, as are value instances and params. Names are compared as zelbyn writes them, the `-orig-id` where there is one, else the id (an attribute without one by `_unnamed` and its index). The runtime's fields are given the name their attribute has in the type they are read in, so two types can give one `-orig-id` to different attributes, and the root is named by its `meta` `-orig-id`. Attributes of one type that share an `-orig-id`, each read under its own condition, are one field, which has the values of the one read. Integers beyond 2^53, which the JavaScript runtime holds as doubles, are compared as doubles. Floats are compared as numbers, as the runtime writes one with an integer value as an integer. An `f8` must be the same double. An `f4`, which zelbyn writes with the shortest digits that give it, also equals the double the runtime widens it to. Which floats are `f4`s is known from which of the runtime's readers read them, so a `switch-on` with cases of several types (`f4` and `f8`, or an integer and a float) is compared by the case it chose, and neither an `f8` nor an integer is compared as an `f4`. The runtime reads some negative `s8` values wrongly, as its XOR of the low word is a signed 32-bit one. The JavaScript runtime (0.11.0) moves past a terminator with `include: true` once more than the C++ runtime and zelbyn do, so a schema that uses it can differ after it. It decodes strings with `TextDecoder`, which removes a byte-order mark at the start of a UTF-16 string, decodes ISO-8859-1 as windows-1252, and has neither UTF-32 nor IBM437, so strings in those can differ or fail there; its `.length` counts UTF-16 units. The script reads the schemas the schema imports, and gives them to both decoders. With `--offsets` it compares offsets instead of values: those of zelbyn's `--offsets` dump, and those the runtime records in debug mode, for every value that is not a set instance. The script exits 1 if any file differs or fails to decode. Run it when the decoder, the `.ksy` compiler or `formats/gif.ksy` changes.

`tools/kaitai_compare/test_compare.py` tests the script and `decode.js`: their helpers, and decodes of schemas whose names only their types tell apart, which must agree, and of one that the decoders read differently, which must be found to differ. Run it when either changes:

```
python3 tools/kaitai_compare/test_compare.py
```

## Corpus check

`tools/ksy_corpus/check.py` compiles every `.ksy` file in a clone of [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats), kept outside this repository, and compares each file's result, compiled or its first error, with the record in `tools/ksy_corpus/expected.txt`. With `--samples` and a clone of [kaitai_struct_samples](https://github.com/kaitai-io/kaitai_struct_samples), it also runs `tools/kaitai_compare/compare.py`, on values and on offsets, for every format that compiles and has samples:

```
git clone https://github.com/kaitai-io/kaitai_struct_formats ../kaitai_struct_formats
git -C ../kaitai_struct_formats checkout f38fd7de89aa6cc171624ba08a0647e06e2ade47
git clone https://github.com/kaitai-io/kaitai_struct_samples ../kaitai_struct_samples
git -C ../kaitai_struct_samples checkout 11ccc86d7697d1b4dcc58ee4b0c5bf8994307e76
python3 tools/ksy_corpus/check.py --samples ../kaitai_struct_samples ../kaitai_struct_formats
```

The record names the commit of kaitai_struct_formats it was made at, and the clone must be at it. At these commits, 18 formats have samples, 43 files, and 41 of them agree in values and in offsets, so the script exits 1. The two that fail are `image/png/libpng-pngtest.png`, which is malformed and which both decoders reject, and `executable/mach_o_fat/MachO-iOS-armv7-armv7s-arm64-Helloworld`, whose schema tests a field it did not read (`mach_o.ksy`'s `uleb128`, where `b3`'s `if` tests `b2`): the JavaScript runtime takes it as 0, and zelbyn, like the Python and Java runtimes, fails with `Absent_Field`. The script exits 1 if any file differs from the record, a file that no longer compiles, now compiles, or fails with another first error, or if any sample differs from the official runtime's decode. Run it when the `.ksy` compiler changes. When a change is meant to change the results, check the differences and run it again with `--record`, which rewrites the record; its diff then shows what the change did to the corpus.

## YAML corpus check

`zelbyn/yaml` parses the subset of YAML that `.ksy` files use. `tools/yaml_corpus/compare.py` checks it against libyaml on every `.ksy` file in a directory, normally a clone of [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats) kept outside this repository. It needs PyYAML built with libyaml (on Arch, `python-yaml`):

```
git clone --depth 1 https://github.com/kaitai-io/kaitai_struct_formats ../kaitai_struct_formats
python3 tools/yaml_corpus/compare.py ../kaitai_struct_formats
```

Every file must give the same node tree from both parsers (kinds, scalar styles and text, and every line and column), or be rejected by zelbyn as outside the subset (anchors, aliases, tags, merge keys, complex keys, directives, multi-document streams, duplicate keys), or be rejected by both. The script exits 1 if any file differs. Run it when the parser changes.
