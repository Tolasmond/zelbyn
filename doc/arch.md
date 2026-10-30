# zelbyn: software architecture

This document describes the implementation in the repository `zelbyn`, as of the commit it is part of: a change to the code updates it. It states what the code does and how its parts fit together. Where a mechanism is more involved than its task makes obvious, a paragraph marked *Reason* gives the requirement that makes it necessary. Sections are cited by number (§).

Figures in the *Reason* paragraphs, times, percentages and instruction counts, are historical observations: each was measured when its decision was made, during development on Linux. The machine, the build options and the Odin version of each were not recorded with it, and none has been measured again since, so they show the size of an effect at the time, not current performance, which `tools/bench` measures (doc/development.md, Benchmark).

Paths are relative to the repository root unless they say otherwise.

---

## 1. Overview

zelbyn is a command-line program written in Odin. It reads a binary file using a format description written in a subset of Kaitai Struct's `.ksy` language, and writes the decoded contents to standard output, as a text dump or as JSON.

A run has four stages. Each stage is the work of one package, and each hands its result to the next as a data structure:

```
  schema.ksy ──► yaml.parse_into ──► yaml.Node tree ──► ksy.compile ──► metadata.File_Format (the plan)
  (and the schemas it imports)                                                 │
  input file ────────────────────────────────────────────► reader.read ◄───────┘
                                                               │
                                                               ▼
                                                        field.Value_Tree ──► dump.write_text / dump.write_json ──► stdout
```

1. **Parse.** The `yaml` package parses each schema's text into a tree of YAML nodes. Each node carries its line and column.
2. **Compile.** The `ksy` package checks those trees against the supported subset of Kaitai Struct. It compiles them into a *plan*: a tree of `metadata.Node` values with every name resolved and every expression parsed and type-checked. Expressions are parsed and resolved by the `expression` package.
3. **Decode.** The `reader` package walks the plan over the input bytes and builds a *value tree* (`field.Value_Tree`).
4. **Write.** The `dump` package walks the plan and the value tree together and writes them out.

The plan and the YAML trees live in one arena, which is freed with the plan. The value tree does not refer to the plan, so the plan can be freed while the tree is still in use (§12).

`zelbyn gen` stops after the compile: the `codegen` package writes the plan as Odin source, a package that decodes the format as `reader` does, for other programs to build with their own code (§10).

**Performance is measured cold.** zelbyn is a terminal tool: one process reads one schema and one file, then exits. Every cost of a fresh process counts: compiling the schema, which a generated Kaitai parser does ahead of time, taking memory from the operating system and touching each page of it for the first time, and running code for the first time. On small files the schema compile costs more than the decode. Several mechanisms below exist for those costs, and an optimization that pays only when one process decodes many files, such as reusing a tree's memory, is not made. A profile taken in a loop over one file misleads: its page faults land in whatever touches new memory first.

## 2. Repository layout

| Path | Contents |
|---|---|
| `main.odin` | The program (package `main`): runs `cli` on the process's arguments, stdout and stderr |
| `zelbyn/cli/` | The command line: its options, `--param`, the decode and the dump, and `zelbyn gen`, writing to the writers it is given |
| `zelbyn/arena/` | `Arena`: the lock-free arena that the plan, the YAML trees and the value tree are allocated in |
| `zelbyn/data/` | The runtime: `Data_Type`, `Reader` (a bounds-checked cursor over a byte slice, with bit reads), `Parse_Error`, and what both the decoder and generated code read and evaluate values with; and the state of a decode by generated code |
| `zelbyn/file/` | `read_entire_file`, which reads a schema file with the system calls it needs |
| `zelbyn/yaml/` | The YAML-subset parser |
| `zelbyn/expression/` | The expression parser, resolver, direct-form classifier and printer |
| `zelbyn/ksy/` | The `.ksy` compiler |
| `zelbyn/metadata/` | The plan: `File_Format`, `Node`, counts, lengths, terminators, checks and expression nodes |
| `zelbyn/field/` | The value tree: `Value`, `Instance`, `Span` and `Value_Tree`, and `write_value`, which writes a value as the text dump and error messages show it |
| `zelbyn/reader/` | The decoder, the expression evaluator and the string decoders |
| `zelbyn/dump/` | The text and JSON writers |
| `zelbyn/codegen/` | The code generator: Odin source that decodes a plan's format as the decoder does |
| `tests/` | The test package and the schemas the import, params and recursive-type tests read (`tests/schemas/`) |
| `tools/bench/` | The cold benchmark and its optional Kaitai Struct C++ reference |
| `tools/kaitai_compare/` | A comparison of decodes, and of offsets, with the official Kaitai Struct JavaScript runtime |
| `tools/ksy_corpus/` | The corpus test: every schema of `kaitai_struct_formats` compiled, against a record, and the samples of `kaitai_struct_samples` compared with the official runtime |
| `tools/codegen_corpus/` | The code of every schema of `kaitai_struct_formats` generated and built, and the samples decoded with it, compared with the decoder's decode |
| `tools/codegen_tests/` | Every decode of the tests made again with the code generated from its plan, and compared |
| `tools/yaml_corpus/` | A comparison of the YAML parser with libyaml |
| `tools/check.py` | The checks a change must pass, in one command, and the optional corpus checks |
| `view/` | The viewer (`zelbyn-view`), a program of its own that shows a decoded file in the terminal, on Linux only; nothing of zelbyn's imports it |
| `view/rows/` | The viewer's rows: a decoded tree as an outline of values, sets and arrays, expanded and collapsed, whose window is found without stepping through the rows before it, the expanded rows under each kept in a treap that counts the rows under them; it imports no terminal library, and is tested with zelbyn |
| `view/hnoss/` | [hnoss](https://github.com/Huseynteymurzade28/hnoss), the terminal UI library the viewer draws with, a git submodule pinned to a commit |
| `.github/workflows/check.yml` | CI: `tools/check.py` on each push to `main` and each pull request |
| `.github/workflows/release.yml` | A GitHub release of the binaries for Linux and Windows on each tag `v*` |
| `.github/actions/install-odin/` | Installs the pinned Odin release, for both workflows |

`.gitattributes` normalizes text files to LF. The repository holds no schemas or sample files of real formats; the tools that need them use clones of `kaitai_struct_formats` and `kaitai_struct_samples` kept outside it (§14).

## 3. Package dependencies

All packages also import from Odin's `core` library. The internal imports are:

| Package | Imports |
|---|---|
| `arena`, `data`, `file` | none |
| `yaml` | `arena` |
| `field` | `arena`, `data` |
| `metadata` | `arena`, `data`, `field` |
| `expression` | `metadata` |
| `ksy` | `arena`, `data`, `expression`, `file`, `metadata`, `yaml` |
| `reader` | `arena`, `data`, `field`, `metadata` |
| `dump` | `field`, `metadata` |
| `codegen` | `data`, `expression`, `metadata` |
| `cli` | `codegen`, `dump`, `field`, `ksy`, `metadata`, `reader` |
| `main` | `cli` |
| `view/rows` | `field`, `metadata` |
| `view` (the viewer's `main`) | `cli`, `field`, `metadata`, `reader`, and hnoss |

`metadata` imports `field` for one procedure, `instance_set` (§6.7), which reads the case that a value-tree instance records. `reader`, `dump` and `codegen` do not import `ksy` or `yaml`: they see only the plan. `data` imports nothing of zelbyn's, as code that `codegen` generates imports it in other projects (§10).

Each package is imported under one name in every file, of the packages, `main.odin`, the tests, the tools and the viewer, so that a name means one package wherever it is read:

| Package | Imported as |
|---|---|
| `arena` | `arn` |
| `data` | `dat` |
| `dump` | `dmp` |
| `expression` | `expr` |
| `field` | `fld` |
| `metadata` | `mdata` |
| `reader` | `rdr` |
| `yaml` | `yml` |
| `cli`, `codegen`, `file`, `ksy`, and the viewer's `rows` | their own names |

`tests/imports_test.odin` checks every import against this table.

## 4. Foundations

### 4.1 `arena`

An `Arena` is a list of `virtual.Memory_Block`s: address space reserved up front and committed as it is used.
- **Blocks.** A new block reserves a target size: that set by `arena_init`, or 4 MB (`ARENA_BLOCK_SIZE`), for the first block, doubled for each block after it. An allocation larger than the target gets a block of its own size, plus its alignment, instead, so that block can be larger than the target, and larger than the block after it, whose target has only doubled. A block commits at least 1 MB at a time (`COMMIT_SIZE`).
- **Zero memory.** Memory comes fresh from the operating system and is never reused before the arena is destroyed, so every allocation is zero.
- **A limit.** `Arena.limit`, 0 for none (`arena_set_limit`), is the bytes the arena may hand out, which an allocation never takes it past. `arena_make` hands out memory inline up to `Arena.end`: the current block's committed memory, or less, where the limit is reached. `set_end` sets it whenever the block's committed memory or the limit changes, as `virtual` commits more than is asked for, half as much again as the block has. Past it, and in the allocator, `within_limit` checks the limit. A new block reserves no more than the limit leaves, but what it is added for.
- **`arena_make(a, T, n)`** allocates `n` values of `T` directly. It bumps the current block's `used` inline when the block has enough committed memory, and otherwise commits more or adds a block. It fails with `Out_Of_Memory` when the allocation would pass the limit, the operating system has no memory left, or the size overflows.
- **`arena_allocator(a)`** presents the arena as a `mem.Allocator`, for dynamic arrays, maps and strings, bounded by the limit. It supports allocation and resizing; the most recent allocation is resized in place when its block has room. Freeing single allocations is not supported.
- **`arena_used`** gives the bytes handed out, from the current block and a count of those before it, and **`arena_destroy`** frees every block.

*Reasons for an arena of its own:*
- **No general heap.** Compiling and decoding make no allocation through `context.allocator` (tested in `memory_test.odin`), and freeing a plan or a tree is one call that releases a few blocks.
- **No lock.** `core:mem/virtual`'s `Arena` takes a mutex on every allocation, and on Linux each lock also runs valgrind client requests, even in release builds. One thread uses each arena.
- **No interface call per value.** `mem.Allocator` dispatches through a procedure pointer and a switch on the allocation mode. The decoder allocates once or more per set instance and per array, so `arena_make` does not go through that interface. When the decoder allocated through it, a slot's dynamic array and its `reserve` at a time, allocation took 35–40% of decoding a 900 KB GIF with `gif.ksy`; allocating each instance in one block, directly, made its cold decode 40% faster and its tree 23% smaller.
- **1 MB commits.** Committing from nothing in small steps takes a system call each time. Committing a whole 4 MB block lets Linux back it with 2 MB huge pages, which it zeroes whole on first touch; that made a small compile take more than twice as long. 1 MB stays below a huge page.

### 4.2 `data`

`Data_Type` is the type of a plan node: `Set`, the signed and unsigned integers `Int8` to `UInt64`, `Float32`, `Float64`, `String`, `Blob`, `Bool` (a bit type of one bit) and `Bits` (any other bit type). It is one byte.

`Reader` holds a byte slice, a position, and the bits left over from the last bit read (`bits`, `bits_left`). Every read checks the bounds first; a read that fails leaves the reader unchanged.
- `read(r, T, order)` reads an integer or float of type `T` in the given byte order, with an unaligned load and, when the order is not the platform's, a byte swap.
- `read_bytes(r, n)` returns a view of the next `n` bytes, without copying them.
- `read_bytes_term(r, term, include, consume, eos_error)` returns a view of the bytes up to `term`, with or without it, and leaves the reader after it or at it. When the data ends first, that is an error with `eos_error`, else the bytes run to the end.
- `read_integer(r, type, order)` reads any integer `Data_Type` except `UInt64`, as an `int`.
- `peek_integer_at(r, pos, type, order)` reads an integer at an absolute position without moving the reader.
- `read_bits(r, n, order)` reads an unsigned integer of 1 to 64 bits (§7.6).
- `at_eof` is true when every byte and every bit left over has been read. `bit_pos` counts the bits read so far, and `align_to_byte` discards the bits left over.

Byte reads neither use nor discard the bits left over, as in Kaitai's runtimes. Every failure is a `Read_Error`; its kinds are listed in §7.10.

`data` is also the runtime of generated code (§10), which imports it in other projects, so it imports nothing of zelbyn's, and holds what the decoder and generated code must do alike, which both call, so that they cannot read or evaluate a value differently:
- **Errors.** `Parse_Error`, `Path_Segment`, `format_path`, `destroy_parse_error`, and `STRING_PREVIEW` and `LIST_PREVIEW`, which `reader` gives by the same names (§7.10).
- **Integers.** `INT_MIN`, `INT_MAX` and the operations on integers of that range, `int_add` to `int_not`, each failing as §6.8 says, which `metadata.int_binary` and `int_unary` dispatch to; `int_size`, a size, count or offset; `float_to_int`, `string_to_int` and `int_digits`, the `.to_i` and `.to_s` of §7.9.
- **Strings and bytes.** `Encoding` and `decode_text` (§7.6), `inflate`, which decompresses `process: zlib` bytes with an allocator, recording an allocation that fails as `Memory_Limit` (`Failure_Recorder`), `trim`, which removes `pad-right` and cuts at a terminator, `substring`, and `bits_of`, a `-bits` field's bits.
- **Values as the dump writes them.** `write_int`, `write_uint`, `write_f32`, `write_f64`, `write_bool`, `write_string` and `write_blob`, which `field.write_value` calls for each type, and the `show_` procedures, which append a value to a `Parse_Error`'s text.

The rest of `data`, in `decoder.odin`, is generated code's alone: the state of a decode and the arrays of its expressions (§10).

### 4.3 `file`

`read_entire_file(path, allocator)` reads a schema file with `open`, `fstat`, `read` and `close`, through a path buffer on the stack. Files that are not regular, whose size is not known, that are empty, or whose path is too long are read with `os.read_entire_file`; so is every file on platforms other than Linux, macOS and the BSDs. A `read` that fails, other than with `EINTR`, which is retried, frees the buffer with the allocator given and returns the error as `os` gives it, so the caller has nothing to free. With an arena, as imports are read, the free does nothing. The `read` calls go through a parameter, `posix.read` by default, which `file_test.odin` replaces to inject failures.

*Reason:* `os.open` copies the name, allocates a `File` and finds the file's full path through `/proc`. Those costs a cold process pays in full, and they were a measurable part of compiling a schema.

## 5. The schema front end

### 5.1 `yaml`: the YAML-subset parser

`yaml.parse_into(src, allocator)` parses `src` and returns its root `Node`, allocating every node and string with `allocator`, which must be an arena. It parses a copy of `src`, made with the allocator; the text of a scalar is a slice of that copy unless it has to be built (a folded line break or an escape). The nodes therefore do not refer to `src`. `yaml.parse(src, &doc)` does the same into a `Document`, which holds the root and its own `Arena`; `destroy_document` frees it. The compiler uses `parse_into`, with the plan's arena.

**What a node holds.** A `Node` is a `Scalar`, a `Map` or a `Seq`. Every node has a 1-based line and column, and the column counts characters, not bytes.
- A scalar keeps its `Style` (plain, single-quoted, double-quoted, literal `|` or folded `>`) and its text after unquoting and folding.
- A map holds its entries in source order; every key is a scalar.
- A sequence holds its items in order.
- Scalars are not interpreted: `0x21`, `yes` and `~` all reach the caller as text.

**What is accepted.** The parser accepts block maps and sequences, flow sequences and maps, the five scalar styles, comments, a byte-order mark, and an optional `---` and `...`. A `#` starts a comment after a blank or at the start of a line. As in libyaml, it also starts one right after a token of a flow collection (`[x,# c`, `{# c`, `"k":# c`) and right after a block scalar's indicators (`|# c`). Inside a plain scalar it is text (`url#frag`, `[x# y]`). An implicit key in a flow collection must have its `:` on the line the key starts on, as libyaml requires (`colon_on_key_line`), so neither a comment nor a line break can come between them. It rejects the following with an `Error`:
- anchors, aliases, tags, merge keys, complex keys, directives, multi-document streams and UTF-16 (a source that starts with its byte-order mark), as `Unsupported`;
- a key that occurs twice in one mapping, as `Duplicate_Key`;
- anything else it cannot parse, as `Syntax`.

Before it parses, it checks the whole source, as libyaml does before it scans (`check_characters`). The source must be UTF-8 made of the characters YAML allows: tab, line breaks and printable characters. A raw control character such as NUL, a byte that is not UTF-8 (overlong and surrogate forms included), U+FFFE or U+FFFF is a `Syntax` error at its line and column, in a comment too. The parser can then read the source byte by byte: a raw NUL would otherwise read as the end of the input (`peek`). An escape (`\x`, `\u` or `\U`) must be a Unicode scalar value, at most U+10FFFF and not a surrogate. Its digits are read as unsigned, so eight of them cannot wrap below that limit. An escaped control character, such as `\0` or `\x01`, is allowed.

An `Error` holds its kind, a line and column, and a message allocated with `context.allocator`. Only the first error is recorded.

**How it parses.** The parser works by recursive descent over the source bytes. Each block collection is parsed at the indentation column of its first key or `-`. The parser can save a position and return to it (`mark`, `reset`), which it uses to look ahead, for instance to tell a mapping key from a plain scalar.

*Reason for a parser of its own:* the compiler's error messages must give the line and column of the key or value they are about. Map entries must keep their source order, because the order of a type's attributes is the order its fields are read in. Duplicate keys must be rejected, and scalar text must reach the compiler uninterpreted, because `0x21`, an expression and a string are all told apart by the `.ksy` key they belong to. Odin's `core` and `vendor` libraries have no YAML parser, and the alternatives were rejected:
- **`odin-yaml`'s decoder** gives no value a source location, overwrites duplicate keys, keeps mappings in Odin maps, which lose their order, and types plain scalars by guessing (`0x21` becomes 33, `yes` a boolean). It also accepts anchors, aliases, merge keys and tags, which would each have to be found and rejected.
- **libyaml at run time,** through that binding's event API, has locations, but brings a C library into the build on every platform, through a binding that has broken on an Odin `core:os` change while zelbyn follows Odin nightlies. libyaml is used only to test this parser (`tools/yaml_corpus`).
- **`.ksy` files as JSON,** read with `core:encoding/json`: nobody writes them that way, and `gif.ksy` would have to be converted. Converting YAML to JSON at build time adds a tool and loses the source locations.

### 5.2 `expression`: parsing, resolution and direct forms

Kaitai Struct expressions appear in `if`, `size`, `repeat-expr`, `repeat-until`, `switch-on`, case keys, `pos`, `io`, `value:` instances and the arguments of a type. The `expression` package turns their text into `metadata.Expr` trees.

**Parsing.** `parse(text, allocator)` is a Pratt parser, and `parse_list` parses a comma-separated list of expressions, the arguments of `t(a, b)`. The precedence is Kaitai's, loosest first:

    ?:   or   and   not   comparisons   |   ^   &   << >>   + -   * / %   unary - ~ +   .

- Every binary operator is left-associative, except `?:`, which is right-associative, and a comparison cannot be an operand of another comparison.
- The literals, and the forms that follow an atom (`.name`, `a[i]`, `.as<t>`, `.name(args)`), are those `parse`'s comment gives, and each makes the syntax variant of `metadata/expr.odin` that is named for it. An integer literal above `max(int)`, up to 2^64 − 1, is a `Big_Literal`; one beyond that, or a float beyond a 64-bit float, is `Unsupported`. As in Kaitai, `sizeof<` always starts a `Size_Of`, even when a field is called `sizeof`.
- `lex_int` hands a literal to `lex_float` only where it already tests for a `.` after the digits, and where an `e` would be an invalid digit, so that integer literals pay nothing for floats. A `.` followed by a name is a member of the integer (`1.to_s`).

The result holds only syntax variants, and does not refer to `text`.

**Resolution.** `compile(text, scope, want, allocator)` parses `text`, then resolves the tree in a `Scope`, replacing every `Name`, `Member`, `Enum_Constant`, `Size_Of`, `Cast` and `Call` with a resolved variant. Resolution sets every node's type to one of `Int`, `Float` (an `f64`), `Bool`, `Bytes` (a blob), `String`, `Array` (every value of a repeated field), `Struct` (a set instance) or `Stream`. The result must have type `want`, unless `want` is `Unresolved`. `compile_list` resolves each expression of a list, whatever its type.

A `Scope`, whose members `resolve.odin` documents, gives the resolver the chain of sets from `_root` to the one the expression is in, whether that chain has a `_root` and whether it is the decoded tree's (`own_root`, `no_root`), whether `_index` and `_` are defined, and in a value instance's own expression the instance, which the resolver marks `cached` (`mark_cached`, §7.9), and whose set it marks `keeps_stream` for any `_io.` member. Everything else comes through callbacks into the compiler: compiling a value instance or a parse instance the first time an expression refers to it (with `type_only` when only its type is needed), sizes for `_sizeof`, `sizeof<t>` and `bitsizeof<t>` (§5.3), encodings for `.to_s(encoding)`, whether two sets are of one type for `?:`, and enums. The callbacks keep `expression` from importing `ksy` (§3), and compiling on first reference lets an instance resolve against the fields compiled before it (§5.3).

The resolved variants, each documented in `metadata/expr.odin`, name what an expression reads: an enclosing set instance (`Instance`: `up` levels out from the current one, `_root`, or an imported schema's `_root`, which the decoder finds as §7.9 says); a field, parse instance or param by its slot (`Field_Ref`, §6.3); a value instance (`Value_Ref`); `_index` and `_` (`Repeat_Index`, `Repeat_Element`); a stream and its `.pos`, `.size` and `.eof` (`Io`, `Io_Pos`, `Io_Size`, `Io_Eof`); and the methods and casts of the subset (`Size`, `String_Length`, `To_I`, `To_S`, `Decode`, `Substring`, `To_Bytes`, `Array_Method`, `Switch_Cast`). Any other method is `Unsupported` (`resolve_call`). An array literal of integer literals from 0 to 255 is a `Bytes_Literal`, as in Kaitai, and any other an `Array_Literal`, whose items `resolve_array_literal` makes of one type.

Type rules:
- A reference to a field read at most once (`metadata.is_single`) has the type of one value: `Int` for an integer or a bit type, `Bool` for `b1`, `Bytes` for a blob, `String` for a string, `Struct` for a set. Any other field gives an `Array`, and indexing it (`Index`) gives one value, of the same type. Indexing `Bytes` gives an `Int`. An `Array` is all the values of a field, an array literal, a value instance of one of those, a `?:` of those, or an item of an array of arrays, and `array_item_type` gives the type of its items: of an item of an array of arrays, that of the first item of the array literal it is in (`first_item`).
- `f4` and `f8` fields are `Float`s. A cast to an integer type, `u1`–`u8` or `s1`–`s8`, resolves to its operand, an `Int`, unchanged, as in Kaitai's JavaScript and Python runtimes; a cast to a user type must be of a `switch-on` field read once (`resolve_cast`), whose field the resolver finds whatever the types of its cases (`resolve_field` with `any_switch`), and it names the cases whose `type` is that type. A `switch-on` field has the type of the values of all its cases (`switch_type`), and with a length and no default, of the `Bytes` an element that no case chooses has; one whose cases are user types or have values of different types cannot be referred to, as in Kaitai it has no type with fields or operators.
- A field is visible to its own expressions, so that those of each element of a repeat see the elements read before it. Its `if` and count, which are evaluated before it has any value, cannot refer to it: until its count is compiled, a reference to it is an error.
- `Io` has the type `Stream`, which only `io`, the branches of a `?:` and the operand of `.pos`, `.size` and `.eof` (`resolve_stream_member`) can have. The resolver marks the set of an `X._io` whose `X` is not an `Instance` (a field, say) `keeps_stream`, so that the decoder keeps the streams of its instances (§7.5); in a value instance, which can be evaluated once the instances it reaches are no longer decoded, also the set of an `Instance` other than `_root` (`keep_streams`).
- `==` and `!=` take two `Int`s, two `Bool`s, two `String`s or two `Bytes`; ordering comparisons take two `Int`s, two `String`s or two `Bytes`, which compare byte by byte, and `+` two `Int`s or two `String`s, which it joins. The rest of the arithmetic takes `Int`s, and `?:` takes `Int`, `Float`, `Bool`, `String`, `Bytes` or `Stream` branches of one type, a `Float` and an `Int`, whose `Int` branch is made a `Float` (`as_float`: a literal's float, or a negated literal's, else `+ 0.0`), `Array` branches whose items have one type, not `Struct` or `Array`, or `Struct` branches of sets of one type, which `Scope.same_type` (the compiler's `same_type_callback`, through `Compiler.type_defs`) confirms; `struct_node` of it is the then branch's set, whose slots the other's share. `+`, `-`, `*`, `/` and the comparisons also take a `Float` and an `Int` or a `Float` (`is_float`), and the arithmetic then gives a `Float`; unary `-` takes a `Float` too. `%` of a `Float` is `Unsupported`, and the bitwise operators take only `Int`s.
- An enum constant resolves to an `Int_Literal` with the value's integer, and `.to_i` of an `Int` to the `Int` itself, so that `.to_i` of an enum value gives its integer.
- `.first` and `.last` have the type of one value of the array, and `.min` and `.max` apply only to an array of `Int`s; of a byte array, all four give an `Int`.
- `_sizeof` alone is the size of the current set's type, and `X._sizeof` that of an attribute or parse instance `X` (a name, or `base.name`), or of the type of the set `X` when it is `_root` or `_parent`. These and `Size_Of` resolve to an `Int_Literal`, the size from `Scope.size_of` in bytes, rounded up, or in bits for `bitsizeof`. The attribute is named, not resolved, so it can come after the expression, as in Kaitai. The `base` of `base.name` is resolved with `Resolver.type_only`, as the size replaces it: a parse instance it refers to is compiled for its type alone, so that the value instance that gives its `pos` can use the size, as `mcap.ksy`'s `ofs_footer` uses `footer.op._sizeof`.

Errors (`expression.Error`) carry a byte offset into the expression's text. `ksy` turns that offset into a line and column (§5.3). `type_name` gives an expression type in words, for messages.

**Direct forms.** At the end of `compile`, `direct_form` classifies the whole expression and stores the result in `Expr.direct`. Subexpressions get no direct form. There are three forms:

| Form | When | Example |
|---|---|---|
| `Direct_Constant{value}` | An `Int` or `Bool` literal (a `Bool` is stored as 0 or 1) | `if: true` |
| `Direct_Field{slot, of_element}` | A `Field_Ref` of type `Int` whose base is the current instance (`up` 0, not `_root` or an imported schema's `_root`), or `_` | `size: len_bytes`, `switch-on: block_type` |
| `Direct_Compare{field, op, constant}` | A comparison (`==`, `!=`, `<`, `<=`, `>`, `>=`) of such a field with an `Int_Literal` on either side. A literal on the left is moved to the right and the operator reversed. | `repeat-until: _.len_bytes == 0` |

The decoder evaluates a direct form without walking the tree (§7.9). The tree stays in place, and the decoder still uses it whenever the direct form cannot give a result.

*Reason for direct forms:* the decoder evaluates a size, count, condition, `switch-on` or `repeat-until` expression once for every element it applies to. In `gif.ksy`, the expressions evaluated per element are exactly the three forms above. Evaluating the tree means a recursive call and a type switch for every node, and for a field reference also a look-up through the frame stack. A direct form is one slot read, plus one comparison for `Direct_Compare`. Keeping the tree beside the direct form means the evaluator alone defines the errors (§7.9). The tree evaluator took 31% of decoding a 900 KB GIF and now takes about 1%, and its cold decode is 23% faster. Compiling every expression to bytecode would cover more expressions, but is a larger change that `gif.ksy` would not use.

**Printing.** `to_string(e)` writes an expression with every operation parenthesized, and a field reference as its path. The tests use it to check how an expression was grouped.

**Walks over expressions.** These procedures switch on an expression's variant, each with its own way through the tree, so there is no visitor that they share. Those that walk the whole tree switch on every variant: a variant added fails to compile until each of them handles it. The others follow an expression of one type, or look for one shape, and handle the variants that it can be; a variant added of that type must be added to each of them. `tests/expression_walks_test.odin` keeps this table true: `expression_walks_inventory` finds every such switch in `zelbyn/`, and fails on one not listed here, or listed as exhaustive and `#partial`; `expression_variants_walked` requires a check for every variant of `Expr_Variant`, in a schema that puts each variant of type `Struct`, `Stream` and `Array` through the walks of its type, and compiles, decodes and prints it.

| Procedure | File | Variants | What it does |
|---|---|---|---|
| `resolve` | `expression/resolve.odin` | All | Resolves a parsed tree in place |
| `write` | `expression/print.odin` | All | Prints a tree (`to_string`) |
| `reach_of` | `expression/resolve.odin` | All | The most levels above its instance a value instance reaches |
| `note_escapes` | `ksy/types.odin` | All | The first expression in a set that reaches out of it (§5.3) |
| `eval` | `reader/eval.odin` | All | Evaluates a tree (§7.9) |
| `write_ev` | `codegen/exprs.odin` | All | Writes the procedure that evaluates a tree as `eval` does (§10) |
| `depth`, `struct_node`, `through_param`, `through_indirect` | `expression/resolve.odin` | Those of type `Struct`: `Instance`, `Field_Ref`, `Index`, `Array_Method`, `Switch_Cast`, `Repeat_Element`, `Value_Ref`, `Ternary` | The level of the instance an expression gives, its set, and whether it is reached through a param or a `?:` |
| `enclosing` | `reader/eval.odin` | Those of type `Struct` | The instance levels above the one an expression gives (§7.9) |
| `write_enc` | `codegen/exprs.odin` | Those of type `Struct` | Writes the procedure that does as `enclosing` for an expression (§10) |
| `keep_streams` | `expression/resolve.odin` | Those of type `Stream`: `Io`, `Ternary` | Marks the sets whose streams a value instance uses |
| `eval_stream`, `stream_reader` | `reader/eval.odin` | Those of type `Stream` | The stream an expression gives |
| `write_stream_value`, `write_stream_reader` | `codegen/exprs.odin` | Those of type `Stream` | Write the procedures that do as `eval_stream` and `stream_reader` for an expression (§10) |
| `array_item_type`, `first_item` | `expression/resolve.odin` | Those of type `Array`: `Field_Ref`, `Array_Literal`, `Value_Ref`, `Ternary`, and `Index` and `Array_Method` of an array of arrays; `first_item` all but `Field_Ref` and `Ternary`, as it is asked only of an array of arrays, whose items are array literals | The type of an array's items, and the first item of an array of arrays |
| `eval_kept` | `reader/eval.odin` | `Field_Ref`, `Ternary` and `Value_Ref` of type `Array` | A cached value instance's array as its field's slot |
| `direct_form`, `direct_field` | `expression/resolve.odin` | A literal, a `Field_Ref`, a comparison | The direct forms |
| `constant_wide`, `is_constant` | `expression/resolve.odin` | Integer literals and operators; literals and array literals | A constant's value, and whether an array literal is constant |
| `resolve_member_size_of`, `resolve_cast` | `expression/resolve.odin` | The operand of `_sizeof` and `.as<t>` | What the size or the cast is of |
| `int_literal` | `ksy/constants.odin` | Integer literals and their negations | A `switch-on` case or `valid` bound |
| `literal` | `codegen/exprs.odin` | The literals | An expression's value as an Odin literal (§10) |

### 5.3 `ksy`: the compiler

`ksy.read_file_format(path, &ff, import_paths)` reads a `.ksy` file with `file.read_entire_file` and calls `ksy.compile(src, &ff, path, import_paths)`.

The package is in six files, each holding what the paragraphs below of the same subject describe:

| File | Contents |
|---|---|
| `compile.odin` | `compile` and `read_file_format`, `Error`, the compiler's state (`Compiler`, `Type_Def` and the records of instances and sets), and what every part uses: errors (`fail`), YAML access, key checks (`check_keys`), identifiers, and compiling an expression |
| `schema.odin` | Schemas and imports, `meta`, encodings, `ks-version`, and `compile_schema`, which compiles the top-level type and what was put off |
| `types.odin` | Types and the sets compiled from them: `build_type`, enums and params, finding a type or an enum, `compile_fields`, sets reused for a type that contains itself (`note_escapes`), value and parse instances, the callbacks of `Scope`, arguments and `parent` |
| `attributes.odin` | Attributes: `compile_field`, primitive, bit and string types, `switch-on`, counts, lengths, terminators and `-bits` |
| `sizes.odin` | `_sizeof`, `sizeof<t>` and `bitsizeof<t>` from the YAML spec |
| `constants.odin` | `valid` and its bounds, and the constants of a schema: integers in YAML scalars, bytes and lists of them, booleans, and `switch-on` cases |

A procedure or type used by one file only is private to it (`@(private = "file")`); one that other files of the package use is private to the package (`@(private)`).

**Allocation.** Everything a compile allocates goes in `ff.arena`: the YAML trees of the schema and its imports, the plan, and the compiler's working data (types, maps, lists). The plan uses the YAML trees' strings as they are. A compile makes no allocation through `context.allocator`, apart from an error's message and path (tested in `memory_test.odin`); `read_file_format` reads the schema's text with `context.allocator` and frees it after the compile.

*Reason for one arena:* a second arena costs a mapping and its first pages in every compile, and freeing the working data early saves nothing a process that exits soon after needs. Keeping the YAML trees lets the plan use their strings without copying them. The compile of `gif.ksy` leaves about 75 KB in the plan's arena that the plan does not need.

**Errors.** A `ksy.Error` has a kind, a 1-based line and column (0 for `Read_Failed`), a message, the file it is in (the schema, or one it imports; "" for source compiled without a path), and an `os.Error` for `Read_Failed`. The kinds, `Read_Failed`, `Syntax`, `Unsupported` and `Invalid`, are documented where `Error_Kind` is declared; a duplicate YAML key is `Invalid`.

Only the first error is recorded. When an expression error has an offset and the expression is a plain or simply quoted scalar on one line, the column points at the character the offset names.

**Schemas and imports.** `load_schema` checks a schema's top level and `meta`: `id`, `endian`, `bit-endian`, `encoding` (one of `ENCODINGS`, below), `ks-version` (no newer than 0.11, `KS_VERSION`), `imports`, and the documentation keys, which are ignored. It builds the schema's types, then reads each schema in `imports`: a name relative to the importing schema's directory, or, starting with `/`, found in the first of the import paths that has it. Each schema read is recorded by its cleaned path, before its own imports are read, so a schema imported twice, or by a schema it imports, is read once. `meta_of` turns the `endian`, `bit-endian` and `encoding` of a `meta` into a `Meta`, over the one it inherits. An `endian` that is a `switch-on` is checked (`check_endian_switch`: its keys, and each case `le` or `be`) and kept as `endian_switch`, with the name of the type that declares it, which the types declared in it inherit; a `bit-endian` that is one is `Unsupported`. The top-level type of each schema has its schema's `Meta`, so an imported schema keeps its own.

**Types.** `build_type` turns the top level and every entry of `types:` into a `Type_Def`. A `Type_Def` holds the type's YAML spec, its schema, the type it is declared in, its `Meta`, its nested types, its checked `instances:` entries, its enums and its params. A nested type has the `Meta` of the type it is declared in, under its own `meta` if it has one (`type_meta`): the keys of the schema's `meta`, with its `id` and documentation keys checked and ignored, and `imports` `Unsupported`. As in the official compiler, the `Meta` follows where a type is declared, not where it is used. It checks the keys of every attribute and instance, so that a key outside the subset is rejected even in a type nothing uses. `find_type` looks a type name up in the current type, then in each enclosing type outward, then as the top-level type of the type's schema, by its `meta` `id`, and among the top-level types of the schemas that the type's schema imports. A path, `a::b::c`, finds `a` so, then each further name among the types declared in the one before. `find_enum` finds an enum name in the current type and its enclosing types, innermost first, and a path, `a::b::e`, among the enums of the type `find_type` finds for `a::b`. An `enum` key (`check_enum`), and through `Scope.find_enum` an enum constant (`find_enum_callback`, which finds the type of the set in `Compiler.type_defs`), are looked up this way. A `to-string`, at the top level or in a type, only defines how Kaitai's tools show its instances, which nothing zelbyn writes does: `check_to_string` parses it, so that a syntax error or an expression outside the subset is still rejected, and does not resolve it, as the official compiler does not resolve its names either.

**Sizes.** `size_of_callback` is `Scope.size_of`. It finds the type of the set it is given in `Compiler.type_defs`, a list of each set compiled and its type, and computes the size from the YAML spec, as the official compiler does: `type_bits` sums the sizes of a type's attributes, and `attr_bits` gives an attribute's: its `size` when that is a constant expression (`expression.constant` folds integer literals and operators, as the decoder would evaluate them, and the result must fit an `int`), else the size of its `contents`, its primitive or bit type, or its user type, times a constant `repeat-expr`. `if` is ignored. Any other `repeat`, the peek extensions, `switch-on` (even with a `size`), `size-eos`, and a `terminator` or `strz` without a `size` have no fixed size, and neither has a type that contains itself (`Type_Def.sizing`); the error names the attribute, as a path through the types it is in (`c.d`). Bit fields are added without the alignment they are read with, as in that compiler, so `sizeof` of `b4, u1, b4, u1` is 3 although reading it takes 4 bytes. `_sizeof` of a repeated attribute, which the official compiler fails on, is `Unsupported`, and that of a param or value instance is `Invalid`.

*Reason for sizes from the schema:* `sizeof<t>` can name a type that no field uses, which has no plan nodes, and a field's `valid` can use the size of its own type (`ofs_first_aux` in `elf.ksy` has `min: _sizeof`), whose fields are still being compiled. The spec has the size either way, and summed as the official compiler sums it, gives its values.

*Reason for a list of sets, not a map:* every compile records every set it compiles, and few use sizes. A map made the compile of `gif.ksy` 2–3 µs slower, 2–3%; the list costs no more than the measurements' noise of 1 µs.

**Encodings.** `encoding` finds an encoding's name in `ENCODINGS`: the canonical names and aliases of the official compiler's `EncodingList`, compared ignoring case, for the encodings the decoder supports. Each gives a `metadata.Encoding`: `None` for ASCII and UTF-8, whose strings keep their bytes, and one for each of UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ISO-8859-1, windows-1251, windows-1252 and IBM437, whose strings are decoded (§7.6). Any other name is `Unsupported`.

**Enums.** Each value of an enum is a name, or a mapping of `id`, `doc` and `doc-ref` whose `id` is the name. Values and names must be unique within the enum.

**Params.** Each entry of `params:` has an `id` and a `type`: an integer type, `bool`, `bytes`, `str`, or the name of a user type, which is looked up from the type the param is of when an argument is given for it. An integer param may have an `enum`. `struct`, `io` and `any` are `Unsupported`. The top-level type of the schema compiled can have params: `compile_schema` gives its set `args` that are `Root_Arg` expressions, which the decoder evaluates from the arguments it is given. The argument of a param of a user type is bytes, which the decoder reads as an instance of the type: `root_arg_sets` compiles the type into a set of its own (`Root_Arg.set`), as the instance a caller of Kaitai's runtimes makes from bytes, with no `_parent`, and no `_root` unless it is the top-level type of its schema (`Compiler.rootless`); its type cannot have params, which nothing could give.

*Reason for `Root_Arg`:* the root is read as any set with params is, its arguments evaluated as its instance starts, so the decoder needs no case of its own for it, and the plan does not change with the arguments of each decode.

**Compiling a type into a set.** `compile_fields(td, set, chain)` compiles the attributes and instances of `td` as those of the plan node `set`. `chain` is the scope: the sets that enclose `set`, outermost first, followed by `set`. A field with a `parent` of `up` levels (`Node.parent_up`) has a chain without the `up` innermost sets enclosing it, as its `_parent` is further out (`chain_of`). When `td` is declared in another schema than the field's, the chain starts again at `set`, which has no `_parent` (`chain_of`). At the top level of its schema, `set` is its own `_root`; elsewhere neither it nor the sets inside it have one, as the official compiler passes `null` for both, and `set` is recorded in `Compiler.rootless`, so that its scope, and those of the sets inside it, have `no_root`. `set`, `td`, `chain`, and the set it is inside (`Set_Type.outer`, `Compiler.current`, the set whose fields or parse instance are being compiled, whatever the chain) are recorded in `Compiler.type_defs`.
1. A `Value_Instance` is made for each `value:` instance, and a plan node for each parse instance (any other instance), with no expressions yet. The compiler remembers where each came from in a map, with, for a value instance, the scope of the set's fields.
2. A plan node is made for each param (marked `is_param`), and its id is claimed. A param of a user type is given the members of its argument's set (`copy_members`), so that expressions reach that set's fields, value instances and parse instances through it. When there are params, `set.slot_count` is worked out first from the attributes and their `-bits`, because expressions in the attributes refer to the params, whose slots come last (§6.3).
3. For each attribute of `seq:` in order, `new_attr` makes its node, which is appended to `set.children` before `compile_field` compiles it, so that its own expressions can refer to it. An attribute that follows a bit type, and is not one, is marked `align` (§7.6).
4. `set.slot_count` is set from `metadata.count_slots(set)`, which must match the count worked out first.
5. Each instance's id is claimed. An instance that no expression has referred to, value or parse, is put off in `Compiler.deferred`, and `compile_schema` compiles it once every set is, with `compile_deferred`, which marks the types of its set and the sets it is inside (`outer`, which a chain can skip) as being compiled again, so that its type, or a type it compiles on demand, finds a type that contains itself. A set reused by a field compiled then is finished (`Set_Type.done`), and the field gets its members at once (`copy_members`).

A type is compiled again for every field that uses it, so every field has its own plan nodes, except inside the type itself. `Type_Def.compiling` is the set the type's attributes are being compiled into. A field of the type compiled while it is set, a type that contains itself, is not compiled again: its node's `recursive` is that set, and the set's `Set_Type` records it in `reused_by`. Once the set is compiled, each of those nodes gets its `children`, `slot_count`, `instances`, `parse_instances` and `params`, so the decoder and the dumps read it as they read any set. Until then the resolver finds them through `metadata.members`, which follows `recursive`, so expressions can refer to the fields of the type inside it, as far as they are compiled. The compile callbacks are given the set an expression reaches an instance through, so that an instance that refers to itself through such a field (`child.total` in `total`), which would need its own type to resolve, is `Unsupported` rather than `Invalid`.

The instances of the set and of those nodes are of one type at different depths, and their expressions are evaluated in both. An `Instance` with `up` reaches a different instance from each, so `note_escapes`, called on every expression compiled, records in each set's `Set_Type` the first expression in it, or in a set inside it, that reaches out of it through `_parent`, or, in a value instance, through an imported schema's `_root`. A set reused by a field whose chain, but for the field, differs from the set's own (`reused_deeper`) is `Unsupported` with such an expression, at the expression, once every expression is compiled, the value instances put off among them (`compile_schema`). A field reused with the same chain, as `parent: _parent` gives `elf.ksy`'s `next`, has the same instances enclosing it, of the same sets, and so may. `_root` of the schema decoded is the first frame for all of them, an imported schema's `_root` is the outermost frame read as its top-level set, which the decoder finds at any depth outside a value instance (§7.9), and the `_io` of an enclosing instance is found from the instance the decoder reaches, so none of them is recorded. A value instance can be evaluated once those frames are gone, so it reaches an imported `_root` through `up`, as it does `_parent`. The official compiler rejects the same field accesses, since `_parent` of such a type has no single type, unless a `parent` gives it one.

*Reason for reusing the set:* a type that contains itself would be compiled without end. Reusing the set keeps the plan finite, and fields are still found by slot. Copying the members onto each node that reuses it keeps the decoder and the dumps from following `recursive` for every instance, which cost about 70,000 instructions on that GIF.

*Reason for compiling a type once per field:* expressions in a type can use `_parent` and `_root`, which resolve against the chain of sets enclosing that particular field, and the type's params take that field's arguments. Each field's copy is resolved in its own chain. It also guarantees that no plan node belongs to two sets. The value tree's layout relies on that: a set's slot count, and each child's slot, are properties of that set alone (§6.3).

**Value instances.** A value instance's `if` and expression are compiled the first time an expression refers to it, through `Scope.compile_instance`, or once every set is compiled when nothing refers to it. Both are compiled with `Scope.instance` set to it, in the scope of the set's fields, so they can use the set's fields, params and value instances, its `_io.pos`, `_io.size` and `_io.eof`, and through `_parent` and `_root` those of the sets that enclose it. A value instance can be evaluated for an instance that is no longer decoded, so one that uses `_io` marks its set `keeps_stream`; one that uses `_io.pos` or `_io.eof`, whose values change as the stream is read, or a repeated field, whose values grow as it is read, is marked `cached` (§7.9), and so is one that refers to another value instance. `_index` and `_` are not defined. The `if` must be `Bool`. A flag on its source record detects an instance that refers to itself, from either. Its value can be an `Int`, `Float`, `Bool`, `String`, `Bytes`, `Struct` or `Array`; an expression reaches the fields of a `Struct` one through it (`struct_node` follows its expression), and indexes an `Array` one by the type of its items (`array_item_type`). An `enum` must name an enum visible in the type and applies only to an `Int` value, which keeps its integer, as on an attribute.

**Parse instances.** A parse instance is compiled as an attribute, by `compile_field`, the first time an expression refers to it (`Scope.compile_parse_instance`), or else once every set is. Its `io`, a `Stream` expression, is compiled next, and its `pos` last: until `pos` is set, a reference to the instance compiles it, so a reference from the instance to itself is found. A reference for its type alone (`type_only`) compiles only the attribute, once (`Parse_Source.typed`), and is not to itself while the rest is compiled. It can have the keys of an attribute other than `id`; `process` is `Unsupported`.

*Reason for putting off instances that nothing refers to:* Kaitai compiles every instance against the whole schema, so a parse instance in a type can use a field of `_parent` after the field it belongs to (`pcf_font.ksy`, `rpm.ksy`), or the parse instance whose type it is inside, through `_root` (`ext2.ksy`, `ds_store.ksy`, `resource_fork.ksy`, `microsoft_pe.ksy`). At the end of its set, neither is compiled yet. Compiled once every set is, it finds both.

**An `endian` that is a `switch-on`.** `compile_type` compiles a type that declares one (`declares_endian_switch`) twice: little-endian into the field's set, and big-endian into a set of its own, with `Compiler.order` set for each, so that the types declared in it, compiled within, take that order. A parse instance compiled later gets the order its set was compiled with (`Parse_Source.order`). The field's set is given an `Order_Switch`: each case's test, `on == key` compiled in the type's scope, its order, the `_` case's order, and the big-endian set. The type cannot contain itself, since a set reused for a field inside it would keep one order, nor be the top-level type of the schema compiled.

*Reason for compiling the type once for each order:* the byte order of a primitive is in its node, so the decoder reads it without asking which order applies; a decoder that looked the order up for every value would make every format pay for the few that switch it. The two sets have the same slots, so expressions and the dumps use the little-endian set's members for an instance of either.

An instance without `pos` is read where its stream is: it is marked `at_stream_pos`, and its `pos` is an `Io_Pos` that the decoder does not evaluate. Kaitai's runtimes read it where the stream is when it is first used, and move the stream past it, so it is allowed only when it reads nothing (`reads_nothing`): when its element has a fixed size of 0 (`attr_bits` with `element_only`, which leaves out the count), a type of no fields, or `size: 0`, or without a `size`, it is a `switch-on` whose cases' types all have (`type_name_bits`), which `attr_bits` gives no size, as the official compiler does. Any other is `Unsupported`.

*Reason for allowing only instances that read nothing:* where Kaitai reads one depends on what has read the stream before it is first used, and reading it moves the stream for what comes after. One that reads nothing gives the same tree wherever it is read; for one that reads bytes, zelbyn would have to reproduce the order in which a runtime first uses each instance.

*Reason for compiling instances on first reference:* an attribute's expression can refer to an instance that is computed from, or read after, the attributes before it. In `gif.ksy`, `if: has_color_table` refers to the instance `(flags & 0b10000000) != 0`, over the field `flags` read just before. Compiled when first referred to, the instance resolves against the fields compiled so far, in the order the decoder reads them. A value instance that nothing refers to is compiled last, as Kaitai compiles every instance against the whole schema: it can refer to a field after its own, and a case's instance can cast the `switch-on` field to a case compiled after it, as `java_class.ksy` does. A value instance is evaluated only when referred to, so this changes nothing in the decode; a parse instance is read, so it is still compiled with its set.

**Attributes.** `new_attr` checks the attribute's `id` and makes its plan node, and `compile_field` compiles the rest into it:
1. **Id and name.** The `id` must be an identifier, unique among the type's attributes, bit fields, params and instances (`claim_id`). The node's `ref_name` is the `id`. Its `name` is `-orig-id` if given, else the `id`, also when `-orig-id` is a list of names (`display_name`). An attribute without an `id` is given the name Kaitai gives it, `_unnamed` and its index in `seq` (`unnamed`), which claims no id; the resolver rejects a field name that starts with `_`, so no expression can refer to it, as in Kaitai.
2. **Type and length:**
   - `contents` makes a `Blob` with a `Fixed_Length` and a `Valid_Eq` check. A `size` beside it is ignored, also in sizes, as the official compiler reads the contents' length whatever it is, and does not compile it.
   - Without a type, `size`, `size-eos` or `terminator` makes a `Blob`.
   - A primitive (`u1`–`u8`, `s1`–`s8`, `f4`, `f8`, with `le`/`be` or `meta: endian`) sets the type and byte order. Under an `endian` that is a `switch-on`, the order is `Compiler.order`, that of the set being compiled (below); outside such a set it is `Unsupported`.
   - A bit type (`b1`–`b64`, with `le`/`be` or `meta: bit-endian`, else big-endian) sets `width` and the bit order. Its type is `Bool` for `b1` without an `enum`, else `Bits`.
   - `str` needs a `size`, `size-eos` or `terminator`, and an encoding, its own or its type's `Meta`'s, which becomes the node's `encoding`; `strz` is a `str` with terminator 0.
   - `builtin_type` compiles these three, with the `Meta` of the attribute's type, for an attribute and for a `switch-on` case.
   - A user type makes a `Set`; written `t(a, b)`, its arguments are compiled by `compile_args` (below).
   - A mapping with `switch-on` makes a `Set` with a `Switch`. Like a user type, it can have a `size`, `size-eos` or `terminator`.
3. **`enum`.** On an integer or bit type, it must name an enum in scope. The field keeps its integer.
4. **`if`.** It becomes `cond`, a `Bool` expression.

   **`parent`.** On a user type (`compile_parent`), it must resolve to an `Instance` that is not `_root`: `_parent`, `_parent._parent` and so on, whose `up` becomes `parent_up`, which the cases of a `switch-on` take too. Any other is `Unsupported`.
5. **Counts (`compile_count`):**
   - `repeat: expr` with a literal becomes `Fixed_Count` with `repeat` set, and with any other expression `Rule_Count`.
   - `repeat: eos` becomes `Eos_Count`, and `repeat: until` becomes `Until_Count`.
   - `-peek` becomes `Marker_Count`.
   - `-while-peek` and `-until-peek` become `Repeat_Count`.
   - With none of these, the count is `Fixed_Count{n = 1}`, without `repeat`.
6. **Length.** `size` becomes a `Fixed_Length` for a literal, else a `Rule_Length`, compiled with `in_repeat` set when the field can have more than one element; `size-eos` becomes `Eos_Length`.
7. **Terminator (`compile_terminator`).** `terminator`, or `strz`'s 0, with `consume`, `include` and `eos-error`, becomes a `Terminator`. `pad-right` applies only with a length, and `consume` and `eos-error` only without one.

   **Process.** `process: zlib` sets `process` on a byte array or a set with a `size`, `size-eos` or `terminator`; on any other type, or without one of those, it is `Invalid`, and on a `switch-on` with a case that is not a user type, or with another algorithm, `Unsupported`.
8. **`-bits`.** It becomes the node's `Bit_Field`s, in order of their lowest bit.
9. **Children.** A user type's fields are compiled with `compile_fields`, in a chain extended by the new node, and then its arguments, which can refer to the type's members through an element of the field read before (`groups[_index - 1].total`). For a `switch-on` field, `compile_switch` compiles each case's type into its own node, which has the field's name and ref_name: a user type into a `Set` with its own arguments, and a primitive, bit or string type with `builtin_type`. As the official compiler compiles them, a string case gets the field's length, and its own terminator and `pad_right` from the field's keys, and the other types none, so they are read without the field's `size`. A `switch-on` field may have `consume`, `include` and `eos-error` without a terminator when a case is `strz` (`has_strz_case`). `on` is an `Int`, a `Bool` or a `String`. Case keys must be integers or enum constants, of the whole range an expression has, −2^63 to 2^64 − 1, as the decoder compares the value of `on` in full (`eval_wide`), and as the official compiler takes them; `int_literal` takes them from an `Int_Literal`, a `Big_Literal` or negations of one (as `-1` parses), as it takes `valid` bounds, only when each negation is within −2^63 to 2^64 − 1, as evaluating it would be (a bound such as `-(-18446744073709551615)` is left to be evaluated, and fails with `Integer_Overflow`); `true` or `false` when `on` is a `Bool`, or string literals when it is a `String`, and `_` is the default case.
10. **`valid` (`compile_valid`).** It is compiled after the children, so that an `expr` can refer to the fields of a set through `_`, defined as the value checked, with `in_repeat` set for a repeated field. Each value of `eq`, `min`, `max` and `any-of` is compiled with `compile_bound`: an integer literal is read with `parse_int`, whose literals are an expression's (`expression.int_literal_value`), and anything else as an expression of the type of the field's values. A value whose expression is a literal (an enum constant resolves to one) is also kept as a `Scalar` of the field's type, and one that does not fit is `Invalid`. A blob's values are lists of bytes, `[0xfe, 0xff]`, or `Bytes` expressions. When every value is a literal, the check is a `Valid_Eq`, `Valid_Range` or `Valid_Any_Of` of `Scalar`s, as `contents` makes too. Otherwise it is a `Valid_Expr`, whose checks compare `_` (a `Repeat_Element` of the field) with each value, as `Binary` expressions the compiler builds: `eq` one `==`, `any-of` one `or` of `==`, and `min` and `max` a `>=` and a `<=`, each with its own error. `expr` is one `Bool` check. `in-enum` becomes a `Valid_In_Enum` of the sorted values of the field's enum, which `check_enum` found. A boolean always takes a `Valid_Expr`, since `Scalar` has no booleans. A user type takes only `expr`, and `min` and `max` only integers.
11. **`repeat-until`.** It is compiled last, with `_` defined as the field's element, so that it can refer to the element's fields, and `_index`, which the decoder gives as the count of elements read, the element's index plus one, as the official compiler's JavaScript, C++ and Java do (its Python tests before it counts).

`compile_args` compiles the text between the parentheses of `t(a, b)` with `expression.compile_list`, in the field's scope with `in_repeat` set for a repeated field. There must be one argument per param, each of the param's type: `Int` for an integer, `Bool` for `bool`, `Bytes` for `bytes`, `String` for `str`, and a `Struct` of the param's type for a user type, whose set (`expression.struct_node`) `compile_args` returns. `compile_user` compiles a type's arguments after its fields, which they can refer to, in a repeat through the elements read so far, but before them for a type with a param of a user type, whose node needs its argument's set. An argument whose set is still being compiled, one enclosing the field, is `Unsupported`, as its members are not all made.

*Reason for the param's members being its argument's:* the instance a param holds was read as a field of that set, so the parse instances, value instances and nested sets of that set are the ones its slots were filled by, compiled with that field's `_parent` and `_root`. A type compiled for the param alone would have nodes of its own, compiled against no particular enclosing sets.

The instances enclosing the argument's are not those the decoder reaches through the param, which are the ones enclosing the instance that holds it. So the resolver rejects, as `Unsupported`, a reference to a value instance through a param whose expressions reach more levels above the instance it is evaluated for (`reach`) than there are fields between the param and that instance. `_io` of a param is that of its argument's instance: the resolver marks the param `keeps_stream`, and once every expression is compiled, `compile_schema` marks the set of its argument too (`Compiler.param_args`). The same holds through a `?:` on sets, whose value instances are compiled for the then branch's set: `through_indirect` finds the nearer of the two in one walk.

`check_keys` checks the keys of each mapping (the top level, `meta`, a type, an attribute, an instance, a param, an enum value, a `switch-on` type, a `valid`) against per-context lists:
- Unknown keys are `Invalid`.
- Kaitai keys outside the subset are `Unsupported`.
- One of zelbyn's own extensions where it does not apply is `Invalid`.
- Any other key that starts with `-` is ignored, as the official Kaitai tools ignore such keys.

The context of an error message ("attribute a") is formatted only when there is an error.

**Extensions.** `-orig-id`, `-peek`, `-while-peek`, `-until-peek` and `-bits` were made so that a port of the SQLite schema zelbyn used before `.ksy` could describe its format and reproduce its dumps byte for byte. The "Schemas" section of `doc/usage.md` gives their exact meaning, and how each is written in standard Kaitai.

## 6. The plan (`metadata`)

### 6.1 `File_Format`

A `File_Format` holds the format's name, its root `Node`, and the `Arena` that the plan and everything the compiler allocated are in. `destroy_file_format` frees the arena.

### 6.2 `Node`

A `Node` is one field, and `plan.odin` documents each of its members where it is declared. They say:
- how its elements are read: `type`, `order`, `width`, `align`, `count`, `length`, `terminator`, `pad_right`, `process` and `encoding` (§6.4, §7.6);
- whether, and for a parse instance where: `cond`, and `pos`, `at_stream_pos` and `io` (§6.6);
- what a set holds: `children`, `slot_count`, `instances`, `parse_instances`, `params` and their `args` (§6.3, §7.5);
- how a set's type or byte order is chosen per instance: `switch_on` (§6.7) and `order_switch` (§5.3);
- how a set stands to the sets around it: `parent_up`, `recursive` (§5.3) and `keeps_stream` (§7.5);
- its names: `name`, shown in the dumps and error paths, and `ref_name`, the id expressions use;
- its checks and subfields: `valid` (§6.8) and `bits` (§6.5);
- the type a set is compiled from: `type_info`, a `Type_Info` (its name, and the type it is declared in) that every set compiled from one type shares, made by `compile_fields` the first time it compiles the type, so that generated code can give the type one struct (§10). The decoder does not read it.

The plan is a tree, but for a type that contains itself. Each field has its own node, even when several fields have the same type (§5.3), and there are no cycles but those through the `children` a node of such a type shares with the set it reuses. The decoder and the dumps walk the plan as the value tree leads them, so they never follow a cycle further than the input does.

### 6.3 Slots

An instance of a set has one *slot* for each of its values' fields, in this order: each parse instance; each child, followed by one slot for each of its bit fields; each param.
- `count_slots(set)` counts them, and the compiler stores the count in `set.slot_count`.
- `slot_of(set, i)` is the slot of child `i`. Parse instance `k` is in slot `k`, and `param_slot(set, k)` is the slot of param `k`.

The resolver stores a field's slot in its `Field_Ref` when it resolves the name, so the decoder and the evaluator find a field's values by indexing, with no look-up by name.

*Reason for recording `slot_count` on the node:* the decoder makes one allocation per set instance, sized from the slot count (§7.5). Recording the count avoids recounting the children and bit fields for every instance. In debug builds, the decoder checks the recorded count against `count_slots` for every instance it reads.

### 6.4 Counts, lengths and terminators

`Count` is a union:

| Variant | Elements read |
|---|---|
| `Fixed_Count{n, repeat}` | `n`; `repeat` when the schema repeats the field, so that it is an array even of one element |
| `Rule_Count{expr}` | The value of an `Int` expression; none when it is negative. |
| `Marker_Count{markers}` | 1 when every marker (an integer at an offset from the current position) matches the input, else 0. A marker that cannot be read does not match. Nothing is consumed. |
| `Repeat_Count{type, value, until, order}` | While (`until` false) or until (`until` true) the integer at the current position equals `value`. It is peeked, never consumed. With `until`, reaching the end of the input first is an error. Each element must consume input. |
| `Eos_Count` | Until the end of the stream, counting bits left over. Each element must consume input. |
| `Until_Count{expr}` | Until `expr`, evaluated with `_` set to the element just read and `_index` to the count of elements read, is true. Each element but the last must consume input. |

`is_single(node)` is true for a `Fixed_Count` of 1 without `repeat` and for a `Marker_Count`: fields read at most once. An expression that refers to such a field gets its value rather than an array. A repeat is an array however its count is written, as in Kaitai, and its expressions have `_index`: `repeat-expr: 1` is a `Fixed_Count` of 1 with `repeat`. The decoder keeps a count of 1, repeated or not, in the slot's cell (§7.4), so the flag changes the type of the field's expressions, not how it is stored.

`Length` is `Fixed_Length{n}`, `Rule_Length{expr}` or `Eos_Length` (the rest of the stream). A computed length that is negative is `Invalid_Length`.

A `Terminator` holds the byte and the flags `include`, `consume` and `eos_error`. Without a length, the bytes run up to the terminator. With a length, those bytes are read, `pad_right` is removed from their end, and they are cut at the first terminator.

### 6.5 Bit fields

A `Bit_Field` (the `-bits` extension) names bits `low` to `high` of an integer field (bit 0 is the least significant), and the unsigned type they are decoded as. Its values go in the slots that follow the integer's slot, and they are dumped right after it. `reader.bit_field_value` extracts the bits from the integer's value, reinterpreted as unsigned.

Bit types (`b1`–`b64`) are fields of their own, read from the stream (§7.6). The values of a `Bits` field are of the smallest unsigned type that holds `width` bits (`bits_type`).

### 6.6 Parse instances

A parse instance is a node with a `pos`. It is read at that offset in the stream of the set instance it belongs to, or in the stream its `io` gives, which does not move: the first time an expression refers to it, or else once the whole input is (§7.5), so that every parse instance is in the tree. Its `cond` is evaluated first, then `io`, then `pos`, or for one marked `at_stream_pos`, the position of the stream it is read in: where its set instance's reader is when an expression first refers to it, or where that instance ended. All of its expressions are evaluated in the set instance it belongs to, so `_io` in them is that instance's stream, as in Kaitai, even when `io` names another.

### 6.7 `Switch`

A `Switch` holds an `Int`, `Bool` or `String` expression `on`, a list of `Switch_Case{value, text, node}` (`value` for an `Int`, and for a `Bool` as 0 or 1, `text`, from a string literal, for a `String`; `type`, the case's user type, for casts), and a `default` node or `nil`, with its `default_type`. `compile_switch` sets the field's `switch_on` before it compiles the cases, and adds each case as it is compiled. Each case's node is a `Set` with its own children, slot count and arguments, or a field of a primitive, bit or string type. Each value-tree instance of a `switch-on` field records the case it was read as, in `Instance.choice`: an index into `cases`, or `field.DEFAULT_CASE` (-1). `instance_set(node, instance)` returns the set that an instance was read as. A value read as a case that is not a set is not an instance but a value of the case's type, and so is a value of a field with a length whose `on` matches no case, with no default, a `[]byte` (§7.5). Without a length, such an element adds no value, so a repeated field can have fewer values than elements, as in Kaitai.

*Reason for recording the case as an index:* the dumps need the case's set to know an instance's fields. The value tree must not refer to the plan, so that the plan can be freed before the tree. An index into `cases` lets the dump find the set in its own copy of the plan.

### 6.8 Checks and expressions

`Valid` is `Valid_Eq{value}`, `Valid_Range{min, max}`, `Valid_Any_Of{values}`, `Valid_In_Enum{values}` or `Valid_Expr{checks}`. The constants of the first three are `Scalar`s: a union with one variant per value type, holding a constant of the type of the field's values. `Valid_In_Enum` holds the enum's values, sorted. Each of a `Valid_Expr`'s checks is a `Bool` expression, in which `_` is the value, and the error that its failure is. A bit field's check has only constants.

`Expr` holds a type, the byte offset of its text in the schema (for errors), a variant (§5.2) and, on a whole expression, its `direct` form. `Value_Instance` holds the `.ksy` name of a value instance, its compiled `if` (`cond`, nil when it has none), its compiled expression, and `cached`, set when either uses `_io.pos` or `_io.eof`, a repeated field, or another value instance.

**Integers.** Every integer of a schema has the range of an `Int` expression, `mdata.INT_MIN` to `INT_MAX`, −2^63 to 2^64 − 1, and every integer operation the rules of `mdata.int_binary` and `int_unary`: `/` and `%` round toward negative infinity, and a division by zero, a shift outside 0–63 and a result outside the range fail. One parser reads every integer literal, `expression.int_literal_value`: decimal without leading zeros, `0x`, `0b` or `0o`, with single `_` between digits. Where a narrower range applies, it is for a reason:

| Integer | Range | Why |
|---|---|---|
| A literal in an expression | 0 to 2^64 − 1; one above `max(int)` is a `Big_Literal`, one above 2^64 − 1 `Unsupported` | The range, with a negation for the negative half |
| A literal in a YAML scalar (`parse_int`: an enum value, a byte, a `valid` bound, a `-bits` number) | The same literal, with an optional sign; `010`, `1__0` and one above 2^64 − 1 are no integer. In a list of bytes and strings (`contents`), an item that YAML 1.1 reads as an integer (`yaml_int`) must be one, else it is an error; any other item, `0o17` or `08` among them, is text | One literal syntax; a `contents` item means what it means to the official tools, which read the YAML as YAML 1.1 does, and is never silently text where they read a number |
| The result of an operation, evaluated or folded (`eval_binary`, `expression.constant`) | The range, each step too | One set of rules, in `int_binary`; `eval_binary` takes a path of its own for two `int`s, which falls back to it when a result does not fit one |
| A size, count, offset or index | An `int`; a larger one is `Integer_Overflow` (an index `Index_Out_Of_Range`), and a folded one is not a constant size | Memory and positions are `int`s |
| A `switch-on` value and its cases | The range | The value is compared in full (`eval_wide`), so an `u8` above `max(int)` chooses its case or the default |
| An enum value | An `int`; a larger one is `Unsupported` | The official compiler holds them as 64-bit signed integers and rejects larger ones |
| A `valid` bound | The type of the field's values (`int_scalar`), checked when the schema is compiled | It is compared with the field's values |
| A `switch-on` case and a `valid` bound written as an expression (`int_literal`) | A literal or its negations, each within the range | As evaluating it would give, without folding other operations |

`tests/expression_eval_test.odin`'s `expression_constant_as_eval` checks that `constant` folds what the decoder evaluates, `tests/ksy_test.odin`'s `ksy_wide_switch` the `switch-on` range, and the error cases of `ksy_errors` the literals and enum values.

## 7. Decoding (`reader`)

### 7.1 Entry points

- **`read(path, &format, &tree, spans, args, limits)`** opens the file and sizes the tree's arena from the file's length: its first block is the larger of 16 times the input and 4 MB. It reads the whole file into the arena, closes the file, and then decodes. Strings and blobs in the tree are views of that copy, or, for strings that are decoded, in the arena too, so the tree owns its input: once `read` returns, it needs neither the file nor the plan.
- **`read_from_bytes(data, &format, &tree, spans, args, limits)`** decodes `data`. Strings and blobs in the tree are views of `data`, which the tree borrows, except strings that are decoded, which are in the tree's arena: the caller keeps it alive and unchanged while the tree is used.

With `spans` (default false), the tree records the span of every value (§8.2). `args` (default none) are the arguments of the params of the root's set, one of each param's type: an `i64` for an integer type, a `bool`, `[]byte` or a `string`, and `[]byte` for a user type; `decode` checks them and copies them into the tree's arena (`root_args`) as `Decoder.args`, which `Root_Arg` gives, and fails with `Invalid_Arguments` otherwise. `limits` (default `DEFAULT_LIMITS`) bounds the tree's memory and the decode's steps (§7.11). Before the root, `read_root_arg` reads the bytes of each user type's argument, in a stream of their own, as an instance of its `Root_Arg.set`, which becomes the argument; an error in it has its path, under the param's name. Both return the number of bytes consumed and a `Parse_Error`. The tree must be zero or destroyed beforehand. After an error, the tree holds what was read before it (§7.10), and is destroyed as usual.

*Reason for the two ownership rules:* views into the input avoid copying every string and blob into the tree. When the decoder reads the file itself, it puts the file's bytes in the tree's arena, so the tree can own them without an extra copy, and no file stays open while the tree is used. When the caller supplies the bytes, the only way to avoid a copy is to borrow them.

### 7.2 Decoder state

The `Decoder`, whose members `errors.odin` documents, holds the reader of the current stream and the offset of its first byte in the input (`base`), so that error offsets and spans are always offsets in the input, and the tree's arena, which holds everything it allocates. Three stacks say where it is:
- `path`, the field and element being read;
- `frames`, the set instances being read, outermost first, each with the index of its stream in `streams`, the length of its path, the set it is read as, and the index of its `_parent`'s frame (`Frame.parent`): the frame before it, unless its field has a `parent`, and -1 for the root. Expressions find `_root`, `_parent` and the current instance in it (§7.9), and parse instances their stream;
- `streams`, the streams that substreams were taken from, outermost first.

Beside them are `kept`, the streams of the instances of sets marked `keeps_stream` (§7.5); `cache`, the values of the cached value instances (§7.9); `pending` and `pending_at`, the parse instances to read once the root is (§7.5); `stack`, the stack that the frames being decoded take as the build that takes the most takes it, and `stack_start`, from which `stack_used` measures the stack really used (§7.5); `steps_left`, the steps the decode may still take (§7.11); the arguments of the root's params; and the first error. The maps are made when they are first needed, so a format that needs none pays nothing for them.

### 7.3 Reading a field

`decode` creates the decoder and reads the root node into `tree.root`. Every field is read by `read_values(d, sink, node)`, which puts the field's values into a `Sink`. A `Sink` is a field's slot and its bit fields' slots, with the instance's cells for them and their capacity. For the root, it is `tree.root`, with no cells.

`read_values`:
1. Discards the bits left over when the node is marked `align`.
2. Evaluates `cond`, and returns with the slot left empty when it is false.
3. For a parse instance, evaluates `io`, if it has one, with `eval_stream`, and then `pos`, both in the instance's stream. `pos` must lie within the stream it is read from (`Offset_Out_Of_Range`, at the position in the instance's stream). With `io`, it pushes the instance's stream onto `streams`, where its frame now finds it, and makes `io`'s stream the current one. It then moves the reader to `pos` and discards the bits left over.
4. Determines the count. A fixed or computed count is known before reading; a `Repeat_Count`, `Eos_Count` or `Until_Count` is not.
5. Reserves room for the values (§7.4), then reads each element with `read_element`. The repeats whose elements must consume input check it themselves, by the bits read (`bit_pos`), and fail with `No_Progress`.

`read_element` pushes a path segment and reads one element:
- **A set element:** `read_instance` (§7.5), which may add no value, for a `switch-on` that chooses no case. `read_element` compares the slot's length before and after to tell, and `read_values`' `repeat-until` loop does too, giving `_` no value then.
- **Any other element:** `read_scalar` (§7.6), whose value is appended to the slot, followed by each bit field's value in its slot. Each bit-field value is checked against its `valid`.

The value is checked against the node's `valid` (§7.7) once it is in the slot, for a set element after its instance is read, so that the check's expressions see the field's values so far under its name. A node without one makes no call.

With spans, it then records the element's span. On success the segment is popped. On error it is left in place, and `fail` has already copied the path.

The decoder is compiled twice, with the compile-time parameter `$SPANS` true and false. `read_scalar` and `field.make_instance` are forced inline.

*Reason for two compilations:* recording spans costs memory and a store for every value. With the choice made at compile time, a decode without spans has no test of it on any path. The forced inlining is needed because each of those procedures now has two callers, and the compiler stopped inlining them: a call for every value and for every instance cost 11% more decode instructions.

### 7.4 Storage for a field's values

Slots are `[]Value` views into storage that the decoder reserves for each field before reading it. The storage depends on the count:

| Count | Storage |
|---|---|
| Known, at most 1, for a field of an instance | The instance's cells for the field's slots (§8.1) |
| Known, at most 1, for the root | One array of exactly that length (`reserve_exactly`) |
| Known, above 1, and at most the bytes left in the stream | One array per slot, allocated once at its exact length (`reserve_exactly`) |
| Known, above 1, and above the bytes left | Grown as the elements are read (`reserve_growing`) |
| Not known in advance | Grown as the elements are read (`reserve_growing`) |

`reserve_growing` starts each slot's array at 8 values and doubles it whenever it fills, copying the values read so far, and their spans, into the new array. Before each element the repeats ask it for room for one value more than the first slot holds, as an element adds at most one to each, so an element that adds none, of a `switch-on` that no case chooses, takes no room. Each slot is updated after every element, so an expression evaluated during the repeat sees the values read so far. `push` appends a value to a slot that has room for it. With spans, `make_values` allocates each array with room for its spans before it (§8.2).

*Reason for the "bytes left" bound:* a count can come from the input, as in `repeat-expr: n` with `n` read from the file. An element that consumes input takes at least one byte, so no more elements than the bytes left can be read before the input runs out. A count above that bound is therefore grown as it is read, and fails with `Unexpected_EOF` where the input ends. Reserving such a count in full would allocate memory for elements that cannot be read, and a count near `max(int)` would overflow the allocation's size. `arena_make` also fails, rather than overflowing, when a size does not fit in the address space, which is `Memory_Limit`. Elements that consume no input can still outnumber the bytes left, which is why the growth path is kept and the count is not rejected; the steps and `max_memory` bound them (§7.11). The tests `count_beyond_input` and `limits_huge_counts` cover these cases.

### 7.5 Set instances, `switch-on`, arguments and substreams

`read_instance` handles one element of a set field:
1. For a `switch-on` field, it evaluates `on`, with `eval_int`, `eval_bool` (as 0 or 1) or `eval_string`, and picks the first case whose value or text equals it, else the default. When no case matches and there is no default, `read_unchosen` reads nothing and adds no value, or for a field with a length, reads the bytes of the length and pushes them as the value, without removing `pad_right` or cutting them at a terminator, but decompressed with `process`, as the official compiler's code does. When the case chosen is not a set, `read_case_value` reads a value with it, as `read_scalar` reads any field, and pushes it.
2. When the field has a length or a terminator, it reads those bytes from the stream.
3. When the chosen set has arguments, it evaluates them (`eval_args`) into an array in the tree's arena. As in the official compiler's code, they are evaluated in the field's stream, after the substream's bytes.
4. With a substream, it pushes the parent's reader and `base` onto `streams`, makes the substream the current stream with `base` advanced, and restores both when the instance ends. The parent's position is already past the substream, whatever the instance leaves unread.
5. It calls `read_set_instance`.

`read_set_instance`:
1. Adds `SET_STACK` to `Decoder.stack`, and fails with `Too_Deep` when there are `MAX_DEPTH` (224) frames, or when the stack passes `MAX_STACK` (768 KB) as `Decoder.stack` counts it (`check_stack`).
2. Allocates the instance in one block with `field.make_instance` (§8.1).
3. Appends the instance to the parent's slot before reading its children, so the instance is in the tree while its children are read.
4. Puts the arguments in the params' cells and slots.
5. Pushes the instance onto `frames`, with the index of its `_parent`'s frame: the frame before it, or `parent_up` steps out along `Frame.parent` from it. For a set with an `Order_Switch`, `choose_order` (not inlined) then evaluates each case's test in the instance, before its fields are read, as Kaitai's runtimes do, and reads the instance as the big-endian set when the first true case, or else the `_` case, is `be`, which the frame then records; with neither, `Undecided_Endianness`.
6. Reads each child into a `Sink` over that child's slots and cells.
7. Keeps the parse instances that no expression has read in `pending` (`keep_pending`, not inlined, which formats without parse instances never call). Once the root is read, `decode` reads them with `read_pending`, in order, each with its set instance's frames, streams, path and stream restored, and any that reading them adds.
8. Pops the frame.

`read_parse_instance` reads a parse instance from wherever the first reference to it is evaluated, as the set its instance was read as has it (`Frame.set`): an expression compiled outside a type whose `endian` is a `switch-on` refers to the parse instances of its little-endian sets. Of an instance that is no longer decoded, a sibling's or a param's argument's, `read_kept` reads it as `read_pending` would, with the frames, streams, path and stream its instance kept, and puts the decoder's back; it builds `pending_at` the first time, so that formats whose expressions never read one pay nothing for the index. It adds `PARSE_STACK` to `Decoder.stack`, and fails with `Too_Deep` when that passes `MAX_STACK`. It finds the instance's frame, marks the slot as read, and switches to the instance's stream. It sets aside the frames, streams and path above the instance's while it reads, and the streams too when the parse instance has `io`, and then puts back the reader and everything it set aside.

*Reason for reading parse instances last:* Kaitai's runtimes read an instance when it is first used, and `tools/kaitai_compare` uses them all after the parse, so an instance can use what is read after it: `chrome_pak.ksy` sizes each resource's `body` from the next element of the array being read. Read with its set, it would fail on every file. The saved context keeps every expression of the instance evaluating as it would have then.

*Reason for the depth limits:* only a type that contains itself can nest instances deeper than its schema, and then an input can nest them as deeply as it likes, as `iso9660.ksy` does on an image whose root directory lists itself as `.`: the official JavaScript runtime overflows its stack on it. Set instances are not all: parse instances read from expressions of their own type nest too (the others are read by `read_pending`, one after another), with the evaluator's frames below each, and `read_parse_instance` sets aside the frames above its instance's, so frames do not bound the stack. Measuring the stack itself would, but a debug build takes several times what `-o:speed` takes, mostly in `eval`, whose own frame is 5.3 KB in a debug build and 1.4 KB with `-o:speed`. A recursive `if` that reads its own parse instance stopped at 104 levels with `-o:speed`, 42 in a plain build and 26 in a debug one, so a schema and an input could decode in one build and fail in another. No count of one kind of frame fixes that, as what each level takes grows with its expressions, the value instances they read and the set instances around them. So `Decoder.stack` counts what every frame that can nest takes, as the build that takes the most takes it: `SET_STACK` for a set instance (`read_set_instance`), `PARSE_STACK` for a parse instance (`read_parse_instance`), `EVAL_STACK` for each call of `eval`, and `VALUE_STACK` for a value instance (`eval_value_ref`), the most measured from where each is entered to where the next is, over the corpus's samples, in debug and `-o:speed` builds, with a few percent more for Windows. `Too_Deep` is decided by it alone, against `MAX_STACK` (768 KB), so every build stops at the same place. `check_stack` checks the stack really used too, against `MAX_STACK` and `STACK_BASE` (8 KB), the frames below the root, as a safety net, and a debug build asserts that it is within `Decoder.stack` and `STACK_BASE` every time a frame is entered, so that the tests, which CI runs in a debug build on Linux and on Windows, find a frame that takes more than its part. What decoding does not nest, a scalar's read, its decoding as text and zlib, fits in the rest of the 1 MB main thread's stack on Windows. `MAX_DEPTH` (224) levels of `SET_STACK` take 760 KB, so plain recursion reaches `MAX_DEPTH`, and writing the dumps, which nest only set instances, has room to recurse through that many. The costs count each `eval` as the most it takes, so `-o:speed` stops far earlier than it would by its own stack: the recursive `if` above stops at 20 levels in every build. `ksy_too_deep` records the depths of such schemas, which every build must reach; no sample of the corpus nests parse instances at all. Counting costs 0.1–0.6% more instructions on the samples' whole runs.

For a set marked `keeps_stream`, `read_set_instance` records each instance's stream, its reader and `base`, in `kept`, through `keep_stream`, once the instance is read: its position is then where the instance ended, which `_io.pos` and `_io.eof` in a value instance evaluated later see. The compiler marks the fields of a type inside itself (`Node.recursive`) as their set is marked, as they are read as it is.

*Reason for keeping only some streams:* a stream is needed only for an `X._io`, or a value instance's `_io`, whose instance is not being decoded when it is evaluated, and the resolver knows every set it can be. The stream of an instance being decoded is in its frame. Storing a stream in every instance would make every tree larger. `keep_stream` is not inlined: inlined into `read_set_instance`, the map insert costs 0.5% more decode instructions on the samples, which have no such set.

### 7.6 Scalars, strings and bit types

`read_scalar` reads one element of a field that is not a set:
- Integers and floats are read with `data.read` in the node's byte order.
- `String` and `Blob` values are views of the stream (`element_bytes`): the bytes of a `Fixed_Length`, `Rule_Length` (evaluated with `_index` set to the element's index) or `Eos_Length`, without `pad_right` and cut at the terminator; or, without a length, the bytes up to the terminator. With `process`, `process_bytes` (not inlined) then decompresses them with `data.inflate`, through `core:compress/zlib`, into the tree's arena, which also holds what inflating allocates, as the decoder allocates nothing outside it; a substream of decompressed bytes counts its offsets from its field's start, as there is none in the file. Bytes that are not a zlib stream are `Decompression_Failed`. A `String` whose `encoding` is not `None` is then decoded by `decode_text`, which calls `data.decode_text`, into UTF-8, in the tree's arena, which takes at most three bytes for each byte of the input (one and a half for UTF-16).
- `Bool` and `Bits` values are read by `read_bit_type`, with `data.read_bits`.

`data.decode_text` decodes UTF-16 and UTF-32 as WHATWG's decoders do: an unpaired surrogate, a UTF-32 value that is a surrogate or above U+10FFFF, and the bytes left at the end that make no code unit each become U+FFFD. A byte-order mark is kept. A single-byte encoding maps bytes from 0x80 through a table of 128 code points: windows-1251 and windows-1252 have WHATWG's tables, which give the bytes the code pages leave undefined their own code points, IBM437 has Python's `cp437`, and ISO-8859-1 has none, as each byte is its own code point. The tables are `rodata`.

*Reason for decoding when a string is read:* the dumps and the evaluator work on UTF-8, so a string decoded once is compared, measured with `.length`, matched by a `switch-on` and written as any other. ASCII and UTF-8 strings, the common case, stay views of the input and pay one comparison, and `decode_text` is not inlined into `read_scalar`. The rules for bad input and the tables are those of the reference decoders the decoder was checked against: Node's `TextDecoder`, which Kaitai's JavaScript runtime uses, for UTF-16 and windows-125x, and Python's codecs for UTF-16, UTF-32, ISO-8859-1 and IBM437, which `TextDecoder` either lacks or decodes as windows-1252. A byte-order mark is kept, as Kaitai's C++ and Python runtimes keep it, where `TextDecoder` removes it.

`read_bits` follows `read_bits_int_be` and `read_bits_int_le` of Kaitai's C++ runtime. It takes the bits left over, then as many more bytes as it needs, and keeps the bits of the last byte that it did not use. In big-endian order the bits are taken from the most significant end of each byte, and in little-endian order from the least significant end. The two orders share the bits left over.

As the official compiler does, the compiler marks every attribute that follows a bit type and is not one (`align`), and the decoder discards the bits left over before it reads it. Nothing else discards them: a bit type after a user type that ended mid-byte reads the bits that type left. A substream starts at its first byte. A parse instance also starts at a byte, where Kaitai's runtimes read on from whatever bits are left over when it is first used.

*Reason for the static rule:* it is the official compiler's, so a schema decodes as in every official runtime, including the cases where a byte read leaves bits behind. `tools/kaitai_compare` checks it.

### 7.7 Checks

`check_valid` checks a value, given the element's index for `_index`. A `Valid_Expr` evaluates each check with `eval_bool`, with the value as `_`, and fails with the error of the first that is false; an error in an expression is the check's. A `Valid_In_Enum` searches the enum's values for the value, as an `int`. The other three go to `check_constant`, which compares the value with the constants of its own type; bit fields use it directly. Range comparisons are written `!(lo <= v)` and `!(v <= hi)`, so that a NaN fails every range. Blobs support equality and `any-of`. A failure is `Not_Equal`, `Less_Than_Min`, `Greater_Than_Max`, `Not_Any_Of`, `Not_In_Enum` or `Expr_False`, reported at the offset where the element started.

*Reason for not calling `check_valid` without a check:* most fields have none, and the call for every element was 5–9% of the decode instructions of GIF files with `gif.ksy`.

### 7.8 Counting rules

- A negative `Rule_Count` reads no elements, as Kaitai's runtimes read none, and so does a negative constant `repeat-expr`, a `Fixed_Count` of 0. A negative length is still `Invalid_Length`, as the JavaScript runtime fails on one too.
- `markers_match` peeks each marker at its offset from the current position.
- `read_repeat` implements `Repeat_Count`. A failed peek ends a `-while-peek` repeat; for `-until-peek` it is `Unexpected_EOF`.

### 7.9 Expression evaluation

`eval_int(d, e, index)` and `eval_bool(d, e, index, element)` evaluate every size, count, condition, `pos`, `switch-on`, `repeat-until` and `valid` check, and `eval_value` evaluates the arguments of a type:
1. **Direct form first.** If `e` has a direct form, `eval_direct` evaluates it. It reads the field's first value from the current frame's instance, or from the instance `_` for `of_element`, and converts it to `int` exactly as the evaluator does.
2. **The tree otherwise.** `eval_direct` gives up when there is no direct form, no frame, no element, an empty slot, or a `u64` value above `max(int)`. Then `eval` walks the tree, and its result or error is the expression's.

`eval` evaluates the tree recursively:
- **Integers.** They are exact from −2^63 to 2^64 − 1 (§6.8): an `int`, or above `max(int)`, a `u64` in `Eval_Value`, from a `Big_Literal`, a `u8` field or param, or an operation. Arithmetic on two `int`s is on 64-bit `int`, and when its result does not fit one, it is done again in `i128`; with a `u64`, it is in `i128` from the start (`eval_binary_wide`, through `mdata.int_binary`), and so are `-` and `~` (`int_unary`). Either way the result is an `int` or a `u64` again (`from_wide`), so `max(int) + 1`, `1 << 63` and `min(int) / -1` are the `u64` 2^63. `.to_i` of a decimal string reaches the same range. A result outside the range, division by zero and shifts outside 0–63 fail with `Integer_Overflow`, `Division_By_Zero` and `Invalid_Shift`, instead of wrapping as Kaitai's C++ and Java runtimes do; within it, results are those of its Python runtime. `/` and `%` round toward negative infinity. A size, count or offset (`eval_int`) or an index above `max(int)` is `Integer_Overflow` or `Index_Out_Of_Range`.

*Reason for `u64` values rather than a type of their own:* Kaitai's `u8` fields and the arithmetic on them (`vlq_base128_le.ksy`) need values up to 2^64 − 1, but nearly every expression stays far below; carried as a separate case, they cost the `int` path nothing, and an expression's type need not track signedness. `and` and `or` evaluate their right operand only when needed.
- **Floats.** An operation with a float is on `f64`, the `int` made a float (`as_float`), as IEEE 754 gives it: a division by zero is an infinity or NaN, not an error, as in Kaitai's JavaScript and C++ runtimes. An `f4` field's value is widened to `f64`. `.to_i` truncates (`float_to_int`) to an `int` or a `u64`, and a value outside −2^63 to 2^64 − 1, or NaN, is `Integer_Overflow`; as a size, count or offset, the result must also fit an `int` (`eval_int`).
- **`Instance`.** `_root` is the first frame. An imported schema's `_root`, outside a value instance, is the first frame read as the schema's top-level set, either set of it when its `endian` is a `switch-on` (`imported_root`, by `Frame.set`). Any other is found by `ancestor`: outside a value instance, by `up` steps along `Frame.parent` from the top frame. In a value instance's expression, `up` 0 is the instance it is evaluated for (`self` in the `Eval_Context`), and the instances enclosing it are found through the `base` that gave `self`, in the context of the expression that referred to it (`caller`). The instance a `Field_Ref` base gives is in the instance its own base gives, and its `_parent` is that instance, or with a `parent`, `parent_up` levels out from it; also for a type that contains itself, whose expressions reach out of it only when its fields inside it have its `_parent` (§5.3); an `Index` or `Array_Method` is in the instance its array is, and `_` is in the caller's current instance. `ancestor` walks the base with `enclosing`, one level per `Field_Ref`, less its `parent_up`, and evaluates the base it stops at in the caller's context; at an `Instance` it continues in the caller, `up` levels further out. A `Switch_Cast` is the instance its operand is, a `?:` the instance of the branch its condition chooses, and a `Value_Ref` the instance its expression gives, which `enclosing` walks in turn, in the context of the value instance.
- **`Field_Ref`.** It reads the slot of the base instance, reading a parse instance first if it has not been read. An empty slot is `Absent_Field`, and a field with more than one value gives the slot as an array.
- **`Repeat_Element`** is `_`, the element the caller gives, and `Absent_Field` when there is none: in `repeat-until`, after an element of a `switch-on` that chose no case.
- **`Index`.** It gives the element of an array, as a `Field_Ref` gives a value, or the byte of a byte array. An index outside them is `Index_Out_Of_Range`. Of a constant array literal (`Array_Literal.constant`, set by the resolver when every item is a literal, a negated `Int` or `Float` literal, or a constant array literal), directly or as a value instance without an `if`, it evaluates only the item it gives (`literal_item`), so that a table such as `dcmp_0.ksy`'s is not made for every lookup. As no item of such an array can fail or depend on the input, that gives what making the array gives, which `tests/literal_item_test.odin` checks by decoding each of its schemas both ways. Any other array literal is made whole, so an error in an item that the index does not give, `[n, 10 / z][0]` with `z` 0, is the expression's, as making the array would give it.
- **`Bytes_Literal`** and **`Array_Literal`** make their value in the tree's arena on each evaluation, so that the tree, which may keep it as an argument, never refers to the plan. A `String_Literal` is the plan's string, which comparisons use as it is, and `eval_value` copies a string argument into the tree's arena, as it can be a literal, a `Substring` of one, or one reached through a value instance or an array literal.
- **`Array_Method`.** `.first` and `.last` give an element as `Index` does, and `.min` and `.max` compare the elements as integers. Of an empty array or byte array, all four are `Index_Out_Of_Range`.
- **Strings.** They are compared byte by byte. `+` joins two strings into a new one, and `.to_s` writes one, in the tree's arena, where they stay until the tree is destroyed; `Decode` decodes bytes with `decode_text`, as a `str` field's, there too. `Substring` is a view of its operand, from the byte of code point `from` to that of `to`, both clamped to its length; it is empty when `to` is not after `from`, and a negative index is `Index_Out_Of_Range`.
- **`To_Bytes`** makes bytes of the array's values in the tree's arena; a value outside 0–255 is `Integer_Overflow`.
- **`Io_Pos`, `Io_Size`, `Io_Eof`** read the stream `stream_reader` gives. With `stream` nil it is `stream_of` the instance (`ctx.self` in a value instance, else the innermost frame's): the stream of its frame, which is the current stream except while a parse instance with `io` is read, or once the instance is no longer decoded, its stream in `kept`. Of an `Io`, it is `stream_of` the instance its expression gives; of a `?:`, that of the branch its condition chooses.
- **`Switch_Cast`.** It evaluates the operand, and fails with `Wrong_Type` unless it is an instance read as one of `choices`.
- **`Value_Ref`.** It evaluates the value instance's `cond`, if it has one, and then its expression, both for its base instance. When `cond` is false the instance has no value, and the reference is `Absent_Field`, as for a field with none. Value instances are evaluated each time they are referred to, except a `cached` one (`eval_cached`): its value, once it has one, is stored in `cache` for the instance, and returned from then on, as Kaitai stores every value instance's. A value that is the values of a field, directly, through `?:` or through another value instance, is kept as the field's slot (`eval_kept`), which the decoder updates as the field grows, so that the array is the field's, as Kaitai keeps a reference to it; a value made from it, such as its `.size`, is kept as it was. `stream_of` gives the stream `_io` refers to: in a value instance, that of the frame of the instance it is evaluated for, or once that instance is read, its stream in `kept`; elsewhere, that of the innermost frame.

`eval_binary` tests for two integers first, and leaves floats, strings and booleans to `eval_binary_other`, so that the other types cost the integer operations, which the decoder evaluates per element, nothing. `eval_string` evaluates a `String` `switch-on`. `eval_stream` evaluates an `io` expression: a `?:` by its condition, and an `Io` by evaluating its instance and finding its stream, in the instance's frame when it is being decoded, else in `kept`.

*Reason for evaluating most value instances each time:* storing a result would need room in every instance for every value instance, or a lookup in `cache` for each use. A value instance over fields read once, params and other set instances gives the same result each time, as a field read once does not change once it has a value, so evaluating it again costs an operation or two and changes nothing. Kaitai's runtimes evaluate a value instance once, when it is first used, and keep that, and only a value that can change makes that visible: `_io.pos` and `_io.eof`, and a repeated field, which an expression can use while it grows, such as the `valid` of its own elements. Those are `cached`, and keep the value they first have, as in Kaitai. So is a value instance that refers to another: each evaluates the one it refers to once, so that a chain of them in which each refers to the one before twice takes one evaluation per link rather than doubling with each. The cost of evaluating the others each time is that a string value instance made with `+` or `.to_s` is allocated again in the tree's arena each time it is evaluated.

*Reason for the index of the `_parent`'s frame in each frame:* with `parent`, the frames between an instance and its `_parent` are not a fixed number. In `elf.ksy`, `next` is a set reused inside itself, read at every depth, and each of its instances has the same `_parent`, the section. A frame's `_parent` is found once, when it is pushed, from the frame it is read in, so `ancestor` takes the same steps at every depth. Formats without `parent` pay for the walk in place of a subtraction: 0.07–0.18% more instructions on the samples measured.

*Reason for finding enclosing instances through the base:* the value tree has no parent links, and an instance reached through a field, such as `header.total`, is not in `frames` once it is read. The base names every instance between it and an instance the caller can find. Only a value instance that uses `_parent` or `_root` walks it.

*Reason for falling back to the tree:* every case in which a direct form cannot produce an `int` is an error case or an absent value. Deferring to `eval` in those cases means that each error's kind, offset and path come from one implementation. `tests/expression_direct_test.odin` checks this. It decodes the same inputs with each schema as compiled and with its direct forms removed, and requires the same errors and dumps. Its cases cover every integer width at its edge values, absent fields and every comparison.

### 7.10 Errors

`fail(d, kind, offset)` records only the first error. It stores the error's kind, its offset in the input (`base + offset`), and the path formatted as `Name[i].Name[i]...`. The path is allocated with `context.allocator`, and `destroy_parse_error` frees it. A `Parse_Error` also carries an `os.Error` for `File_Read_Failed`.

A failed check is recorded by `fail_check`, which adds the value read and what the check expected (`Parse_Error.value` and `expected`), as `field.write_value` writes them, also with `context.allocator`: the constant of `eq` or `contents`, the bound of `min` or `max`, or the values of `any-of` or of the enum of `in-enum`, the first `LIST_PREVIEW` (16) followed by `...`. A string shows its first `STRING_PREVIEW` (64) characters and a blob its first 16 bytes, followed by ` ...`. An `expr` expects nothing it can show, and a set's value is not shown. A bound given by an expression is in a `Valid_Expr` check, `_ == x`, `_ >= x`, `_ <= x` or an `or` of `==`s: `fail_check` evaluates each `x` again, and shows no expected value if one fails then. An error from evaluating a check, such as `Absent_Field`, is recorded as any other, with neither. The command line writes them after the error: `: read 3, expected one of 1, 2`, with `at least`, `at most` or `one of` as the kind needs.

**The tree after an error.** A decode that fails leaves in the tree what it read before the error, and the tree can be walked as a complete one can, by `dump` and by the viewer:
- Every value in it is whole. A scalar is added once it is read, and a set instance once it is made, before its fields are read. An array holds the values read, and its length counts only them.
- The set instances being read when the error came are in the tree, each with the values read in it. The slots of the fields it had not reached are empty, as is that of a parse instance not read yet; a parse instance whose read failed has the values it read.
- A value that fails its `valid` check is in the tree, as it was read, but its `-bits` fields are not, so their slots have one value fewer than the field's.
- With spans, every value has its span. A set instance whose read failed spans from its start to the position of its stream when the error came, which for one of a substream is the substream's end, as when it is read (`set_failed_span`, §8.2).
- An error in the argument of a param of the root's user type comes before the root is read, and leaves the root empty.

A tree read with spans holds the same values and sets as one read without, and the error is the same, unless the decode reached `Memory_Limit`: spans take memory, so with them a decode can stop sooner, at another value. `tests/partial_tree_test.odin` checks each of these. The test helpers, and the limits tests, decode every input of the tests that fails again, with spans the other way and the same limits, compare the two trees but after `Memory_Limit`, check that every value of the one with spans has a span, and walk both with the dumps (`check_failed_tree`). This is the decoder's: code that `zelbyn gen` writes (§10) is not checked for it.

The kinds are those of `data.Read_Error`, each documented where it is declared: from reads and offsets (`Unexpected_EOF`, `Offset_Out_Of_Range`, also for a `pos` outside its stream), counts and lengths, expressions, checks (§7.7), nesting (`Too_Deep`, §7.5), the limits (`Memory_Limit` and `Step_Limit`, §7.11), casts, an `endian` `switch-on` that matches no case, `process: zlib`, the root's arguments, and reading the file.

### 7.11 Limits

Every schema and input either succeeds or fails with an error that names the limit it reached, within bounded memory, stack and time. The stack is bounded by limits on nesting, each set some times beyond the deepest of the corpus of `kaitai_struct_formats` and measured to fit, with one level more, in the 1 MB stack of Windows' main thread in a debug build:

| Limit | Where | Value | Corpus | Bounds |
|---|---|---|---|---|
| `yaml.MAX_NESTING` | `enter_collection` | 128 | 15 | The parser's recursion through collections |
| `expression.MAX_DEPTH` | `nested`, and `Parser.recursion` in `parse_expr` | 64 | 21 | The depth of an expression's tree, which resolving, evaluating and printing recurse through, and the parser's recursion through operands and parentheses, which add none of the tree's depth |
| `expression.MAX_CHAIN` | `resolve_value_ref`, from `Value_Instance.chain` | 32 | 6 | A chain of value instances, each using the next, which resolving, evaluating and the walks that follow a value instance to its expression recurse through |
| `ksy.MAX_NESTING`, `ksy.MAX_STACK` (512 KB) | `enter`, in `compile_type`, `compile_instance`, `compile_parse_instance` and `load_import`; `type_bits` | 64 | 8 | Compiling types, instances found by a reference and imports inside each other, and sizes found through a type; `MAX_STACK`, measured from `compile`, stops a nesting whose levels each resolve deep expressions before `MAX_NESTING` does |
| `reader.MAX_DEPTH` | `read_set_instance` | 224 | — | Set instances nested by the input |
| `reader.MAX_STACK`, as `Decoder.stack` counts it | `check_stack`, in `read_set_instance`, `read_parse_instance`, `eval` and `eval_value_ref` (§7.5) | 768 KB | — | Set instances, parse instances, evaluations and value instances nested by the input and the schema, the same in every build; `Too_Deep` |

Each of the first four is `Unsupported` at the node or expression that passes it, and `constant`'s `any_of_cond` builds the `or` of an `enum`'s values as a balanced tree, so a `valid: any-of` of many values is not deep. The stack measured at the least `ulimit -s` that each of these takes at its limit, in debug and `-o:speed` builds, was at most 799 KB in a debug build and 624 KB with `-o:speed`; a nesting 100,000 deep of each fails with its error.

Memory and time are bounded by `Limits`, which `read` and `read_from_bytes` take:
- **`max_memory`** (`DEFAULT_LIMITS`: 1 GiB, some 300 times the largest tree of the samples, 3.3 MB of a PNG with Exif) sets the tree's `Arena.limit` to the bytes used once the input is read, plus it. Every allocation of the tree goes through `arena_make` (`tree_make`, `make_values`, `reserve_exactly`, `reserve_growing`, `make_instance`) or `arena_allocator`, and a failure is `Memory_Limit`. So do the decoder's own records, its path, frames, streams, maps and the parse instances it keeps (`keep_pending`), whose frames, streams and path it copies, as many as a schema has parse instances for each instance, however few steps they take: each append (`push_record`), copy (`clone_dynamic`) and map insert reports a failure. An append to the path just before an error is reported is not checked, as the error it reports is the decode's. `decode_text` and `process_bytes` give `data`'s `decode_text` and `inflate` the arena's allocator; `inflate` gives it to `zlib.inflate` through a `Failure_Recorder`, which records whether an allocation failed: inflate reports some of those as another error, which is then `Memory_Limit` too, not `Decompression_Failed`. A count larger than the input reserves only what the input can hold, and an element that adds no value takes no room (§7.4).
- **`max_steps`** (`DEFAULT_LIMITS`: 100,000,000) is taken by `read_element`, once an element of a field, set instance or parse instance; by `eval_value_ref`, once a value instance evaluated, so that a chain whose links each use the next twice, which doubles the work with each, ends; and by `take_steps` for each item of an array literal, of `values_to_bytes` and of `.min` and `.max`, also each string that string `+` (`join_strings`) copies. A decode that passes it fails with `Step_Limit`. Every other loop of the decoder and evaluator is bounded by the input or by one of these.

0 lifts either limit. *Reason for the defaults:* they are far beyond any input of the corpus, and bound a decode to seconds and its tree to less than the memory of a machine that runs it. A `repeat-expr` of far more elements than `max_steps`, each of which reads nothing, stops with `Step_Limit` in 0.7 s; the elements of GIF files are read with `gif.ksy` at about 40 million a second, so its steps would take some 3 s. One whose elements each add a value stops with `Memory_Limit` at 1 GiB, in 900 MB of resident memory, as the arena commits only what it hands out.

A compile takes time linear in its schema's size but in one case. A name that must be unique, or is looked up, is compared with each of the others while there are fewer than 64 (`INDEX_FROM`), and found in a map from then on: a key among its mapping's (`yaml`'s `check_key`), and an id among its type's (`claim_id`), a type or an enum among those of the type that declares it (`Type_Def.type_index`, `enum_index`) and a value among its enum's (`build_enums`). A node's column is its byte offset in its line when the source has no multibyte character, which `check_characters` notes; else the parser counts it on from the last it counted on that line (`char_column`), so a flow mapping of many keys on one line is linear too. Each schema of 100,000 types or instances compiles, or is rejected, in under 0.1 s with `-o:speed`, where comparing each key with every other took up to 37 s; `yaml_duplicate_among_many`, `ksy_many_names` and `limits_compile_nesting` time out if that comes back. The case: the resolver looks a name up among the members of its set one by one (`resolve_field`), and an enum constant among its enum's values, so n expressions that each name one of n members take time in n², some 4 s for 40,000.

## 8. The value tree (`field`)

### 8.1 `Value`, `Instance` and `Value_Tree`

**`Value`.** A `Value` is a union of the ten integer and float types, `string`, `[]byte`, `bool`, `^Instance` and `[]Value`, which is never in a tree: it is an item of an array literal of arrays, which only expressions make. Its size is 24 bytes, the size of its largest variants (`string` and `[]byte`) plus the tag.

**`Instance`.** An `Instance` holds `slots: [][]Value` and `choice: int` (§6.7). `make_instance(arena, n, choice, SPANS)` allocates an instance in one block of pointer-aligned words, laid out as:

```
  ┌──────────────────────┬─────────────────────────────┬──────────────────────────┬──────────────────────┐
  │ Instance             │ slots: n × []Value          │ cells: n × Value         │ with spans only:     │
  │ (slots, choice)      │ (a view each, initially     │ (storage for a slot that │ n × Span, the span   │
  │                      │  empty)                     │  holds at most 1 value)  │ of each cell's value │
  └──────────────────────┴─────────────────────────────┴──────────────────────────┴──────────────────────┘
```

`Instance.slots` points at the slot table. `make_instance` returns the cells separately, and `instance_cells` finds them again from the slot table. A slot whose field is read at most once is a view of its cell. Any other slot is a view of its own array (§7.4). The slot of a parse instance is `nil` until it is read, and then never `nil`, even when it has no values.

*Reason for the single-block layout:* an instance's header, its slot table and the values of its single-value fields are created together and freed together. One allocation per instance replaces one allocation for the instance, one for its slot table, and one for every slot. `gif.ksy`'s most numerous instances, its data sub-blocks, have two single-value fields each. Every slot gets a cell, whether its field turns out to be single or not, so that an instance's size depends only on `slot_count` and not on counts known only at decode time (§6.3).

**`Value_Tree`.** A `Value_Tree` holds `root: []Value`, its `Arena`, and `spans`, set when it was read with spans. Every instance, slot table, cell and array of a tree is in that arena, together with the input when `read` decoded it, the strings that were decoded or made by expressions, and the decoder's `path`, `frames`, `streams`, `kept` and arguments. `destroy_value_tree` frees it all and resets the tree to zero. The arena inside a `Value_Tree` holds the list of its blocks, so a copy of a `Value_Tree` shares those blocks, and only one of the copies may be destroyed.

### 8.2 Spans

A `Span` holds an offset in the input and a size: from the stream's position before a value was read to its position after, as Kaitai's debug mode records them and the Kaitai Web IDE shows them. A set instance's span covers its substream, when it has one. A `-bits` field has its integer's span. Positions are of whole bytes, so a bit type that takes only bits left over has size 0.

In a tree read with spans:
- the span of a value in a cell is in the instance, after its cells (`cell_spans`);
- the spans of an array are kept just before it, in reverse: that of element `i` at index `-1 - i` (`array_span`).

`value_span(instance, k, i)` gives the span of value `i` of slot `k`, and `root_span(tree, i)` that of a root value. Params, which are not read, have no span. When it records the span of a value in a cell, the decoder finds the instance from the innermost frame. The span of a set instance whose read failed is recorded as the error unwinds through it, when the frames of the instances being read are left pushed (§7.10), so `set_failed_span` finds the instance whose cell holds it among them. Only a failed read calls it, so a decode that succeeds pays nothing for it.

*Reason for this layout:* a span is found from the slot alone, so no instance or array needs a pointer to its spans. A first layout that gave every value its own array, with its spans before it, made the tree of GIF files with `gif.ksy` 73% bigger; keeping the spans of single values next to the cells makes it 38–44% bigger, and decoding with spans 29–31% slower (12% on the smallest sample).

## 9. Output (`dump`)

Both writers walk the plan and the value tree together, from `format.root` and `tree.root`. For a set value, `instance_set` gives the set the instance was read as (§6.7); any other value in a `switch-on` field's slot, a case's value or a `[]byte`, is written as a scalar. Each child's values are written from its slot, followed by its bit fields' values from theirs, and then the parse instances' values. Value instances and params are not written.

- **`write_text(w, format, tree, offsets)`** writes one line per scalar: its path (`Name[i].Name[i]...`, root included), ` = `, and the value. A set gets no line of its own. Values are written as follows:
  - integers in decimal, and `b1` values as `true` or `false`;
  - floats with `%v`;
  - strings quoted;
  - blobs as `<N bytes>` followed by their first 16 bytes in hex, and ` ...` when longer.

  `field.write_value` writes each, as error messages show a failed check's value too (§7.10).

  With `offsets`, which needs a tree read with spans, each line ends with ` @0x` and the value's offset in uppercase hex. The path is built in one `strings.Builder` and truncated back after each child.
- **`write_json`** writes compact JSON on one line, followed by a newline. A set instance is an object whose keys are its field names in schema order, each followed by its bit fields' names, then its parse instances' names, and every field's value is an array. Blobs are lowercase hex strings, encoded in 1 KB chunks. NaN and infinities are `null`. Strings that are printable ASCII without `"` or `\` are written as they are; any other string is escaped as `json.marshal` escapes it, except that a byte that is not part of valid UTF-8 is written `\u00NN`, so the output is always valid JSON.

Both write to an `io.Writer`. A writer's error stops the dump and is returned.

## 10. Code generation (`codegen`)

`codegen.generate(format, options, allocator)` writes the source of one Odin package that decodes the format of a plan, which `zelbyn gen` writes to a file (§11). doc/usage.md ("Generating code") gives what the package declares: a struct for each type of the schema, `Args`, `read` and `write_text`. The package is in five files:

| File | Contents |
|---|---|
| `codegen.odin` | `generate`, the generator's state, the walk of the plan, the structs' names and layout, and `merge` |
| `read.odin` | The procedures that read sets, fields and their elements, and the writing of lines of code |
| `exprs.odin` | The procedures that evaluate expressions, find the instances enclosing one (`enclosing`), evaluate value instances, and give streams |
| `checks.odin` | The procedures that check values and record a check that fails |
| `api.odin` | `Args`, `read` and `write_text`, the structs, and the procedures that dump them |

**The decoder's steps.** Generated code does for the plan what the decoder does, step by step. Each procedure the decoder runs for a node or an expression, `read_values`, `read_element`, `read_instance`, `read_set_instance` and `choose_order`, `read_scalar`, `element_bytes`, `byte_length`, `check_valid`, `fail_check`, `eval` of each variant, `enclosing`, `eval_stream`, `stream_reader` and `eval_value_ref`, has a procedure generated for it, whose comment names it, that reads the same bytes, evaluates the same expressions in the same order, and calls `data.fail` where the decoder calls `fail`, with the same offset, so that the first error recorded, and its path, are the same. The state is the decoder's (§7.2), in `data.Decoder`, kept as the decoder keeps it: the stream and its `base`, the path, the frames, the streams, the kept streams (`keep_stream`), the parse instances to read once the root is (`keep_pending`, `read_pending`), with `read_parse_instance` and `read_kept`, which set aside the frames, streams and path above an instance's, the values of cached value instances (`cached`, `keep_cached`), and the expressions' `Eval_Context`, whose `base` is the procedure generated for the decoder's `enclosing` of the expression that gave `self`. A set instance is known to `data` by its address alone: every struct begins with a `data.Header`, the set it was read as, which a frame records too, and its `switch-on` case (`Instance.choice`). What both must compute alike, reads, integers, text and checks, is in `data`, which both call (§4.2).

*Reason:* the decoder defines every value and every error, and its tests, the corpus check and the comparisons with the official runtime check it. Code that takes the same steps through the same state gives the same results, and a step taken differently shows as a difference, which `tools/codegen_tests` looks for in every decode of the tests (§14). Generating from the plan, which `ksy` compiles, keeps parsing, imports, the resolution of types and expressions, and schema errors in one place, the front end (§5).

Generated code leaves out the limits of §7.11: there is no `MAX_DEPTH`, no stack accounting (`Decoder.stack`) and no `Too_Deep`, no `max_memory` (an allocation that fails is still `Memory_Limit`) and no `max_steps`. Nor does it record spans or write JSON. Direct forms (§5.2) are not generated, as the tree gives the same values, which `expression_direct_test.odin` checks.

**Structs.** Each type has one struct, which every set compiled from it shares (`Node.type_info`), as they all have its members (`same_layout` checks it): a field for each child, followed by each of its bit fields, then each parse instance, then each param. A set of a plan built by hand, which has no type, has a type of its own (`type_of`). A field's storage (`Storage`) holds what the decoder's slot does (§8.1):
- a field read at most once holds its value: `Plain`, with a bit of `_have` that says whether it has one, or when it can have none once read, `Maybe`, and a set instance or a `switch-on`'s union, which can be `nil` (`Pointer`, `Union`);
- a repeated field's values are a `[dynamic]` array (`Array`), which, as a slot, has no value missing however many it has;
- a param holds its argument (`Param`), an integer as an `i128`, as the decoder's slot can hold a `u64`;
- a parse instance's bit of `_read` is set as the decoder makes its slot not `nil`, when it starts to read it.

The `switch-on` field of cases of several types has a union of them (`switch_variants`), named for the struct and the field, one for the field's nodes in every set of the type (`field_key`); with one type, that type.

**Values.** An expression's value has a type for its `Expr_Type`: `Int` an `i128`, which `data`'s integer operations keep within `INT_MIN` and `INT_MAX`, as the decoder's `int` and `u64` together are; `Float` an `f64`; `Bool`, `Bytes` and `String` as they are; `Struct` an instance's address, cast to its struct where a field of it is read, the struct of the set that holds the field (`Generator.owners`); `Stream` a `data.Stream`; and `Array` a `data.Array`, of a field's values its `[dynamic]` storage, which it reads as the field grows, as the decoder's kept slot (`eval_kept`), for a `switch-on` field's union through an `Item_Proc` generated for it, which makes each value the expression's (`array_of_union`), and of any other array, its items, made for it. `_` is the address of a value of its field's type (`Eval_Context.element`).

**Procedures.** The procedures are written as the code written before them names them (`need`), from a list of work, starting from the sets: `read_set_N` and `read_members_N` for each set, `N` its number in `Header.set`; `read_field_N`, `read_element_N` and the procedures they call for each member of a set, by its node, so that the sets that share members, a type that contains itself, share them; `ev_N` for each expression, which calls its operands' (`operand`), `enc_N` for each that is the base of a value instance or of such a base, and `vi_N` for each value instance; `parse_T`, a `data.Parse_Proc`, for each struct with parse instances, which reads one as the set its instance was read as, as `Frame.set` says; and `dump_T` for each struct. Each procedure is written into a `Proc` of its own, and its references to others are marked (`ref`). `merge` then keeps one of each class of procedures that are the same: two are the same when their text is, but for their own names, and the procedures they call are the same at each place. A partition is refined, from the text with its references blanked, by the classes of the procedures called, until no class splits, and each reference names the procedure kept of its class (`resolve_refs`).

*Reason for merging:* a type is compiled once for each field of it (§5.3), and the code of most of those fields is the same. Before it, `png.ksy`, with the `exif.ksy` and `icc_4.ksy` it imports, gave 57,000 lines, and the corpus 784,000; merged, 27,000 and 471,000, most of what remains a procedure of each field of a type.

**Names.** A struct has its type's path of names in Ada_Case, without the top-level type of the schema compiled but for that type, and with an imported schema's (`type_name`); a name taken, `Args` and Odin's `Maybe` among them (`RESERVED`), is followed by a number (`unique_name`). A field has its id, or its `-bits` name, as an identifier (`identifier`, which `field_name` gives the tests): the characters that cannot be in one made `_`, an Odin keyword followed by `_`, and in its struct, followed by a number when it meets another (`unique_names`), as a member of `Args` is (`args_names`, which the tests' recording uses too). The procedures are numbered, and the constants of byte literals are `BYTES_N`.

## 11. The program (`main.odin` and `cli`)

`cli.execute(args, stdout, stderr)` runs a command line, whose options doc/usage.md (Running) gives, and returns its exit code; `main` calls it with the process's arguments, stdout and stderr. A command line whose first argument is `gen` is `zelbyn gen` (doc/usage.md, "Generating code"): `gen` parses the rest into `Gen_Options` with `core:flags`, loads the format as `run` does, and writes the package that `codegen.generate` gives it to `<out>/<package>.odin`, making the directory. Everything it writes goes to the writers it is given, so `tests/cli_test.odin` runs it in the test process, on writers of its own, one of which fails. It parses the command line with `core:flags`, whose errors `print_flags_error` writes as `flags.print_errors` does, which writes to the process's own stdout and stderr. `parse_args` takes `--param` out before `core:flags` parses the rest, and `write_usage` adds its line to the usage.

*Reason for parsing `--param` apart:* as a list field of the options, `core:flags` costs every run some 7,000 instructions, given or not, 0.3% of decoding a small file.
- `--help` prints the usage and exits 0.
- A usage error prints the error and the usage on stderr, and exits 2.

`run` performs the work:
1. Loads the format with `ksy.read_file_format`.
2. Turns the `--param`s into the arguments of the root's params (`root_args`), by each param's type: an integer (decimal, or `0x`, `0o`, `0b`), `true` or `false`, hex bytes, or a `str`'s text. A missing, unknown, repeated or malformed one exits 2.
3. Decodes with `reader.read`, with spans when `--offsets` is given, and the arguments.
4. Writes the dump through a `bufio.Writer` on stdout, and flushes it.

Errors go to stderr, and nothing reaches stdout unless decoding succeeds. A schema error names its file, line and column. A load, read, decode or write error exits 1. `main` sets `context.logger` to a logger that writes to stderr, at level `Warning` and above.

In debug builds (`ODIN_DEBUG`), `main` runs `cli.execute` under a `mem.Tracking_Allocator`. Leaked or doubly freed memory is reported on stderr and turns exit code 0 into 1. The program frees everything it allocates before it exits, so that this check holds.

## 12. Memory and ownership

| Data | Allocated in | Freed by | Refers to |
|---|---|---|---|
| Schema text (`read_file_format`) | `context.allocator` | The end of `read_file_format` | — |
| Imported schemas' text, YAML trees, compiler working data | `File_Format.arena` | `metadata.destroy_file_format` | Nothing outside the arena |
| Plan (`File_Format`) | `File_Format.arena` | `metadata.destroy_file_format` | The YAML trees' strings, in the same arena |
| Value tree, with its decoded strings | `Value_Tree.arena` | `field.destroy_value_tree` | Its input: owned when it came from `read`, borrowed when it came from `read_from_bytes` |
| Decoder's `path`, `frames`, `streams`, `kept`, `cache` and arguments | The tree's arena, within its limit (§7.11) | With the tree | — |
| Error messages, `ksy.Error.path`, and `Parse_Error.path`, `value` and `expected` | `context.allocator` | The matching `destroy_error` / `destroy_parse_error` | — |
| Generated code: the generator's working data | An arena of `generate`'s own | The end of `generate` | — |
| Generated code: the source | The allocator `generate` is given | The caller | — |
| Generated code: the instances, arrays, strings decoded and made, and bytes decompressed by `read` | `context.allocator` | The caller, best as an arena | Its input and the bytes of `Args` |
| Generated code: `data.Decoder`'s records | An arena of its own (`decoder_init`) | `decoder_destroy`, as `read` returns | — |

`Value_Tree` and `File_Format` each hold their `Arena` by value, so a copy shares its blocks: only one copy may be destroyed, and a block that one copy adds is unknown to the other. They are filled in place, through a pointer, and the tests' `Decoded`, which embeds a tree, is never returned by value. Because the tree does not refer to the plan (§6.7), the plan can be destroyed before the tree. The test `value_tree_outlives_schema` checks this. The test `value_tree_from_read_outlives_file` checks that a tree from `read` survives the deletion of its file.

## 13. Tests

`tests/` is one package, `tests`. `doc/development.md` lists the commands that must pass before a commit: three `odin check` runs with `-vet -strict-style`, and the tests built without and with `-o:speed`, with `ODIN_TEST_FAIL_ON_BAD_MEMORY`.

| File | What it covers |
|---|---|
| `helpers.odin` | `SAMPLE_KSY`, a schema of no real format with the shapes the decoder's tests need, and `sample_input`, which makes its inputs of any size; decoding helpers, with or without spans, which with `-define:ZELBYN_CODEGEN_RECORD=<dir>` record each decode for `tools/codegen_tests` (`record_decode`), check the tree of each that fails (`check_failed_tree`, §7.10), and that the viewer's rows of each tree, all expanded, give its text dump (`check_rows`, in `rows_test.odin`); `tree_lines`, every value of a tree, sets and spans included; finding a field's slot and values by name |
| `decode_malformed_test.odin` | Empty, malformed and truncated inputs and a missing file, their error kinds, offsets and paths; counts larger than the input; negative counts, which read nothing, and lengths |
| `partial_tree_test.odin` | What the tree holds after a failed decode (§7.10), with and without spans: arrays, instances and parse instances cut short, a value that fails its check, with and without `-bits`, a substream, a `switch-on`, `process: zlib`, and an error before the root |
| `rows_test.odin` | The viewer's rows (`view/rows`): those of `SAMPLE_KSY` as they are expanded and collapsed, their spans and text, and moving to a parent and siblings; random expands, collapses and moves against an outline that makes every row; an array of a million values and of sets, whose windows, expanding and collapsing take steps that do not grow with it and format only the window's values, also with half a million of its rows expanded, whose steps grow with their logarithm; a preview that cuts strings and blobs; no allocation through `context.allocator` once a model is made, and none kept of a window's rows once freed |
| `memory_test.odin` | That decoding, with and without spans and with `process: zlib`, `read` and `ksy.compile` make no heap allocations; that errors allocate only their message or path, and a failed check's value and expected; tree lifetime and reuse after destroy |
| `checks_test.odin` | Byte order, `valid` checks and bit fields, on hand-built plans, with the value and the expected value each failed check reports, shortened when long |
| `expression_parse_test.odin` | Parsing, precedence and syntax errors, and type errors, also of floats |
| `expression_walks_test.odin` | That every procedure switching on an expression's variant is in the inventory of §5.2, exhaustive or not as it says, and that every variant of `Expr_Variant` is compiled, decoded and printed, those of type `Struct`, `Stream` and `Array` through the walks of their type, in a schema the official runtime also decodes |
| `expression_eval_test.odin` | Evaluation on hand-built plans: field references, `_parent`, `_index`, conditions, methods, floats and their mixing with integers, `?:` over byte arrays, `.substring` and `.as<bytes>`, the size of other streams, integers above `max(int)` |
| `expression_direct_test.odin` | That direct forms and the tree evaluator give the same results and errors (§7.9) |
| `ksy_test.odin` | The `.ksy` compiler end to end: compile errors with their kinds, lines and columns, and each Kaitai feature of the subset and each extension compiled and decoded, alone and in the combinations that have needed care: types that contain themselves and the depth limits, imports, params (also of the top-level type), parse and value instances, `switch-on`, `valid`, expressions and their methods and casts, encodings, `process: zlib`, and `endian` `switch-on`s. The comment of each test says what it covers. |
| `yaml_test.odin` | The YAML parser's node trees and errors; escapes at the edge of the Unicode range and beyond it; characters allowed raw and those that are not, and bytes that are not UTF-8; comments right after flow punctuation and a block scalar's indicators, and `#` inside a plain scalar; a flow key and its `:` on two lines; a duplicate key after 63, 64, 65 and 100,000 others, block and flow, in ASCII and not, within a timeout |
| `cli_test.odin` | The command line, run in the test process (`cli.execute`): `--help`, the usage errors, `--offsets` with `--dump json`, `--param` in both forms with an argument of each type and each of its errors, `--max-memory` and `--max-steps` and their errors, the errors of loading and decoding, each failed check's message with what it read and expected, and output that cannot be written, each with its exit code and with nothing on stdout when it fails |
| `limits_test.odin` | The limits of §7.11: counts far beyond the input, the steps counted, `Step_Limit` and `Memory_Limit` at their limits and below them, never past `max_memory`, from bytes and from a file, also the decoder's own records, and each nesting limit at it and one past it, with its error |
| `literal_item_test.odin` | That an index of a constant array literal, which evaluates only the item it gives, decodes as the whole array does, with every item type, nested, through value instances and with failing indexes; which array literals are constant; and that an error in an unused item of any other fails the expression |
| `imports_test.odin` | That every import of one of zelbyn's packages names it as §3 says |
| `layout_test.odin` | The layout of the arena and the value tree, on the addresses themselves: alignment of `arena_make` and of the allocator up to a page, also in a block of its own; growth in place of the most recent allocation, past a commit, and moving otherwise, with its bytes; block rollover, the doubling target and a block for a large allocation; `make_instance`'s block, with and without spans, and empty slots in a decoded tree (unread, read no times, a parse instance whose `if` is false); and spans after slots grow, by `repeat: eos` and past the bytes left, of sets, cells and `-bits` fields |
| `file_test.odin` | `file.read_entire_file` with injected `read` failures, at once and after partial reads, and `EINTR`: the error kept, and nothing left allocated, with the heap or an arena (Linux, macOS and the BSDs) |
| `data_reader_test.odin` | `data.Reader` reads and bounds checks, and bit reads in both orders |
| `dump_test.odin` | The text and JSON dumps of `SAMPLE_KSY`, exactly, from trees read with and without spans, and the JSON of a large tree parsing; dump format details, and `field.write_value` |
| `codegen_test.odin` | What generated code declares: names made identifiers and kept apart, the package's name and `data`'s import path, `Args` and the params' types, the same code from each generation, and `zelbyn gen` and its errors; what the code does is `tools/codegen_tests`' check |

Hand-built plans in the tests are made with `plan_node`, which sets `slot_count` from the children it is given. Bit fields are set on a child before the parent is built. `tests/schemas/` holds the schemas that the import, params and recursive-type tests read from files.

## 14. Tools

These are not part of the program's build.

- **`tools/bench/`** measures cold runs: one fresh process per measurement, as zelbyn is run (§1).
  - `main.odin` is a one-shot program. It compiles the schema, reads the file, decodes it with `read_from_bytes` (with spans after `--spans`), and writes the JSON dump to memory. It prints each phase's time, the page faults taken during the decode, and the tree's size. `faults_posix.odin` counts page faults with `getrusage`. `faults_windows.odin` counts them with `GetProcessMemoryInfo`; the two are selected by `#+build` tags. A count that cannot be read, before or after the decode, is printed as -1.
  - `bench.py` builds zelbyn and the one-shot program with `-o:speed`. It runs them 200 times per file it is given, interleaved, and prints medians, including the whole-process time of the CLI (with `--dump json`, or with `--offsets` after `--spans`) and of a process that exits at once.
  - `cpp/` builds an optional reference with the official Kaitai Struct C++ runtime. `generate.js` runs the pinned compiler's `cpp_stl` target, `build.py` compiles the result with `oneshot.cpp`, and the output goes to the ignored `cpp/build/`.
- **`tools/kaitai_compare/`** checks zelbyn's decode against the official Kaitai Struct runtime; doc/development.md gives its use and the runtime's own errors, and the comments at the top of `compare.py` and `decode.js` the details. `compare.py` converts a schema and the schemas it imports to JSON with PyYAML, and `decode.js` decodes the files with the official compiler and JavaScript runtime, pinned at 0.11.0 in `package.json`, in debug mode, which records where each value was read. `compare.py` compares the result value by value with zelbyn's `--dump json`, or with `--offsets` the start of every value that is not a set instance with zelbyn's `--offsets` dump. Two things it must know of each value come from the runtime's side:
  - **Its name.** Fields are matched by the names zelbyn writes, the `-orig-id` where there is one. `decode.js` names each field of the runtime's from the spec of the type its object was generated from, which it finds by the object's class (`CLASSES`), so a name belongs to one type, and nested or imported types that share a short name keep their own params and parse instances. A name can be any string: fields are held in objects without a prototype, and each result is in an envelope, `{"value": ...}` or `{"error": ...}`. Attributes of one type that share an `-orig-id` under exclusive conditions are one field (`merge_fields`).
  - **Whether a float is an `f4`.** zelbyn writes an `f4` with its shortest digits, and the runtime the double it widens to, so a float read as an `f4` is also equal when zelbyn's rounds to it as an `f4`; an `f8` must be the same double. `decode.js` records what each of the runtime's primitive readers read, over each span of each stream (`READS`), and gives the paths of the values an `f4` reader read, by the spans of their debug records (`readKind`), so that a `switch-on` with cases of several types is compared by the case chosen.

  `test_compare.py` tests these helpers, and decodes schemas that need them.
- **`tools/ksy_corpus/`** is the corpus test. `main.odin` compiles every `.ksy` file under a directory, with the directory as the import path, and prints one line for each: compiled, or its first error's kind, file, line, column and message. `check.py` compares those lines with `expected.txt`, which records them and the commit of `kaitai_struct_formats` they were made at, and `--record` rewrites it. With `--samples`, it runs `tools/kaitai_compare/compare.py`, on values and on offsets, over the samples in a clone of `kaitai_struct_samples` of every format that compiles: the files of the format's directory that have a `.license` file beside them, other than `.txt` and `.json` files.
- **`tools/codegen_tests/`** checks generated code against the decoder on every input the tests decode. `check.py` runs the tests with `-define:ZELBYN_CODEGEN_RECORD=<dir>`, which makes `decode_bytes` and `decode_file` record each decode: the package generated from its plan, once, named by the hash of its code, the input, the arguments as the literal of its `Args`, and the decoder's result, the text dump or the error as the command line writes it. Decodes that reach a limit of §7.11 are not recorded. It then builds one program, with `-vet -strict-style`, that imports every package and decodes each case with its plan's, and compares each result with the decoder's. `tools/check.py` runs it with the other checks.
- **`tools/codegen_corpus/`** checks generated code on the corpus. `check.py` generates the package of every `.ksy` file of a clone of `kaitai_struct_formats` that zelbyn compiles, builds each, with `-vet -strict-style`, with a program that decodes a file and writes its dump or error as the command line does, and with `--samples`, decodes the samples that `tools/ksy_corpus` decodes with both, comparing exit code, output and error.
- **`tools/yaml_corpus/`** checks the YAML parser. `main.odin` prints the YAML parser's node tree for each file. `compare.py` compares it with libyaml's, through PyYAML, over every `.ksy` file in a clone of `kaitai_struct_formats` kept outside the repository.
