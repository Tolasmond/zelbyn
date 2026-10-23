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
gnrcrdr <schema.ksy> <file> [--dump tree|json] [--offsets] [--import-path dirs] [--param name=value]...
```

Decodes `<file>` with the Kaitai Struct schema and writes the decoded tree to stdout. For example:

```
./gnrcrdr.bin formats/gif.ksy data/855.gif
./gnrcrdr.bin formats/gif.ksy data/855.gif --dump json
./gnrcrdr.bin formats/gif89a.ksy data/855.gif
./gnrcrdr.bin ../kaitai_struct_formats/common/bcd.ksy number.bin --param num_digits=6 --param bits_per_digit=4 --param is_le=false
```

When the schema's top-level type has `params`, `--param name=value` gives the argument of each: an integer (decimal, or with `0x`, `0o` or `0b`), `true` or `false`, bytes in hex (`0a1b`), also for a user type, whose instance the decoder reads from them, or a `str`'s text as it is.

`formats/gif.ksy` is `gif.ksy` from [kaitai_struct_formats](https://github.com/kaitai-io/kaitai_struct_formats), unchanged (CC0-1.0), and decodes the samples as the official Kaitai Struct runtime does (see [Kaitai runtime check](#kaitai-runtime-check)). Options may also be written `--dump=json`. `--import-path` lists the directories that a schema's absolute imports (`/common/x`) are found in, separated by `:` (`;` on Windows), as the official compiler's `-I` does. `--help` (or `-h`) prints usage.

### Output

`--dump tree` (the default) writes one line per decoded value: its path, ` = `, then the value. Fields are listed in schema order, and `[i]` is the index within each array. A set (such as `logical_screen_descriptor`) gets no line of its own, and a field that was not read (its `if` was false, or no `switch-on` case matched) gets none either. A `switch-on` field with a `size` or `size-eos` that matched no case is a blob.

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
| 2 | Usage error: a missing or extra argument, an unknown flag, a bad `--dump` value, or `--param`s that do not give one valid argument for each param of the schema's top-level type |

`--dump` values are case-sensitive.

A `.ksy` schema that cannot be compiled is reported with its file (the schema, or one it imports), line and column, and the kind of problem: `Syntax`, `Unsupported` (valid YAML or Kaitai outside the supported subset) or `Invalid`:

```
error: formats/x.ksy:6:14: Unsupported: a: process xor(1) is not supported; only zlib is
```

Decoding checks every value against its field's `contents` and `valid`. Set instances nested more deeply than the decoder allows, which only a type that contains itself can do, are `Too_Deep`, a cast to a user type of a `switch-on` field read as another case is `Wrong_Type`, an `endian` `switch-on` that matches no case is `Undecided_Endianness`, and `process: zlib` bytes that are not a zlib stream are `Decompression_Failed`. A value that does not pass stops the decode with `Not_Equal`, `Less_Than_Min`, `Greater_Than_Max`, `Not_Any_Of`, `Not_In_Enum` or `Expr_False` (`valid: expr`), at the offset and path of that value. A file that is not a GIF fails on its signature:

```
error: Not_Equal at 0x00000000 in gif[0].hdr[0].magic[0]
```

## Schemas

`.ksy` schemas are read with gnrcrdr's own YAML parser, which accepts the YAML that `.ksy` files use and rejects anchors, aliases, tags, merge keys, complex keys, multi-document streams and duplicate keys. The compiler supports this subset of Kaitai Struct, and rejects everything else, naming the key and its location:

| Area | Supported |
|---|---|
| Top level | `meta`, `params` (in an imported schema), `seq`, `types`, `instances`, `enums` (each value a name, or a mapping of `id`, `doc` and `doc-ref`), `doc`, `doc-ref`, `to-string`; an entry of `types` has the same keys, with `params` anywhere |
| `meta` | `id`, `endian` (`le`, `be`, or in a type, a `switch-on` with `cases` of `le` and `be`), `bit-endian`, `encoding`, `ks-version` (0.11 or older, the Kaitai version gnrcrdr follows), `imports`; `title`, `application`, `file-extension`, `xref`, `license`, `tags` (ignored). Also in a type, without `imports`, where its `id` is ignored |
| Attributes | `id` (an attribute without one is named `_unnamed` and its index in `seq`, as in Kaitai, and no expression can refer to it), `type`, `size`, `size-eos`, `terminator` (with `consume`, `include`, `eos-error`), `pad-right`, `process: zlib` (on a byte array, or a user type or `switch-on` of user types, with a `size`, `size-eos` or `terminator`), `contents` (with a `size`, which is ignored, as the official compiler ignores it), `parent` (on a user type: `_parent`, `_parent._parent` and so on, which gives its instances that `_parent` instead of the instance each is read in), `if`, `enum`, `valid` (a value, or `eq`, `min`/`max`, `any-of`, `in-enum`, `expr`; a value is a literal, a list of bytes such as `[0xfe, 0xff]` for a blob, or an expression, in which `_` is the value checked; on a user type, only `expr`), `repeat` (`expr` with `repeat-expr`, `eos`, `until` with `repeat-until`), `encoding`, `doc`, `doc-ref` |
| Types | `u1`–`u8`, `s1`–`s8`, `f4`, `f8` (with `le`/`be` or `meta: endian`), `b1`–`b64` (with `le`/`be` or `meta: bit-endian`, else big-endian; `b1` is a boolean, unless it has an `enum`), `str` with `size`, `size-eos` or `terminator`, and `strz` (NULs included within a `size`; for the encodings, see below), byte arrays, user types (also inside themselves, and the schema's own top-level type, by its `meta` `id`; by path, `a::b`; with `size`, `size-eos` or `terminator`, read from a substream of those bytes; with arguments, `t(a, b)`, when they have `params`), `switch-on` over an integer, a boolean or a string, with `cases` of any of these types, including the `_` default case, also with `size`, `size-eos` or `terminator`, each case of a user type read from a substream |
| Params | `id`, `type` (an integer type, `bool`, `bytes`, `str` or a user type), `enum` (on an integer), `doc`, `doc-ref` |
| Instances | value instances (`value:`, with `if` and `enum`; integers, floats, booleans, strings, byte arrays, set instances and arrays), over the fields and other value instances of their own type and, through `_parent` and `_root`, of the types enclosing it, also those after them, and `_io.pos`, `_io.size` and `_io.eof` of their own instance's stream. Expressions anywhere can refer to them, and to the fields of one that is a set instance; they are evaluated each time, and not dumped, but for one that uses `_io.pos` or `_io.eof`, which has the value it had when first used, as Kaitai gives every value instance: so a value instance used in an `if` of the `seq` saves the position there (`_io.pos`), for a parse instance to read at. Once its instance is read, its stream is as it was then. One whose `if` is false has no value, and an expression that refers to it fails, as for a field with none. Parse instances (`pos:`, or neither `pos` nor `value` for one that reads nothing), with the keys of an attribute other than `id`, and `io`: the stream to read at `pos` in, `_io` or the `_io` of a set instance (`_root._io`, `_parent._io`, `header._io`), or a `?:` of those. A set field's stream can be used once the field is read; one that was not read is absent |
| Expressions | integer and boolean operators (integers are exact from -2^63 to 2^64 - 1, so `u8` values and the like are as Kaitai's Python runtime gives them; an operation whose result is outside, or that divides by zero, fails with `Integer_Overflow` or `Division_By_Zero`, rather than wrap as its C++ and Java runtimes do, or round as its JavaScript runtime's doubles do), float literals (`1.5`, `2.`, `1e3`) and float fields: `+`, `-`, `*`, `/` and the comparisons of a float and an integer or a float, which give a float, as in Kaitai, with IEEE 754's infinity or NaN for a division by zero, string literals (`'...'` as written, `"..."` with escapes), comparisons and `+` of strings, array literals (`[0x50, 0x4b]`, of integer literals from 0 to 255, a byte array, as in Kaitai; any other, an array of integers, floats, booleans, strings, byte arrays or arrays, those all array literals with items of one type, among floats an integer literal being a float), comparisons of byte arrays, `?:` (of integers, floats, booleans, strings, byte arrays or streams, a float and an integer giving a float, of arrays of one item type, other than sets and arrays, or of sets of one type, whose fields and value instances an expression can then use, but not a value instance that refers to the sets enclosing its instance, through `_parent`, as it is compiled for the set of the first branch), field references (a field's own expressions see the elements of a repeat read so far), indexing (`a[i]` of an array or a byte array), `_parent`, `_root`, `_io.pos`, `_io.size`, `_io.eof` (of the substream, inside one; in a parse instance with `io`, still of its type's stream), and the same of the stream of another set instance (`_root._io.size`, `header._io.size`, or of a `?:` of streams), which, once that instance is read, is as it was then, `.size`, `.length` (of a string, in code points), `.to_i` (of a decimal string, a boolean, an enum, or a float, rounded toward zero; a float beyond those integers, or NaN, fails with `Integer_Overflow`), `.to_s` (of an integer), `.to_s(encoding)` (of a byte array: the string its bytes are in that encoding, a string literal of those a `str` can have), `.substring(from, to)` (of a string, in code points as `.length` counts them, clamped to the string: empty when `to` is not after `from`, which Kaitai's JavaScript runtime swaps; a negative index is `Index_Out_Of_Range`), `.first`, `.last`, `.min` and `.max` (of an array or a byte array; `.min` and `.max` of integers), `_sizeof` (of a field, or alone, of its type), `sizeof<t>` and `bitsizeof<t>`, `_index` (also in `repeat-until`, where it is the count of elements read, the index of the element just read plus one, as in Kaitai's JavaScript, C++ and Java runtimes; its Python runtime tests before it counts the element), `_` in `repeat-until`, enum constants (`kinds::two`, or by path, `a::kinds::two`), casts (`.as<t>`: to an integer type, `u1`–`u8` or `s1`–`s8`, which leaves the value as it is, as in Kaitai's JavaScript and Python runtimes; to a user type, of a `switch-on` field read once, which gives the case of that type, whose fields can then be used; to `bytes`, of an array of integers, each of which must fit in a byte, else `Integer_Overflow`, or of a byte array) |

With a `size`, the bytes are read, `pad-right` is removed from their end, and they are cut at the `terminator`, if one is given. Without one, they run up to the `terminator`; `include` keeps it in the value, and `consume: false` leaves the reader at it, as in the C++ and Python runtimes (the JavaScript runtime moves one byte further when `include` is set). `consume` and `eos-error` do not apply with a `size`, nor `pad-right` without one.

A bit type reads on from the bits left over in its stream, in its bit order, and then from as many more bytes as it needs. Bits are left over until something reads them: as in Kaitai, an attribute that follows a bit type, and is not one, starts at the next byte, but an attribute after a user type does not. So the bit type after a user type that ends with bits left over reads those bits, as Kaitai's runtimes do. `_io.eof` is true once every byte and every bit left over is read. A substream starts at its first byte, and so does a parse instance, which in Kaitai's runtimes reads on from whatever bits are left over when it is first used.

A parse instance is read at `pos` in the stream of its type, which does not move, the first time an expression refers to it, as in Kaitai. Any that no expression has read are read once the whole input is, as the official runtime reads them when they are first used after the parse, so they can use fields read after them, such as the next element of their array. Instances that no expression refers to are compiled once every type is, as Kaitai compiles every instance against the whole schema, so their expressions can use any field of the instances enclosing them: one after the field they belong to (`_parent.body.len`), or a field of a parse instance they are inside (`_root.bg.super_block`); one that an expression refers to is compiled there, and uses the fields compiled before it. Every parse instance is in the decoded tree, and an error in one fails the decode, even if nothing uses it. A `pos` outside the stream is `Offset_Out_Of_Range`. An instance without `pos` or `value` is read where its stream is, as in Kaitai: when an expression first refers to it, or else where its instance ended. Kaitai's runtimes also move the stream past it, so what it reads depends on when it is first used; gnrcrdr supports only one that reads nothing, whose type has a fixed size of 0 (a type with no fields, such as one of only instances, or `size: 0`), or a `switch-on` whose cases' types all do, whatever its `repeat`.

A type can contain itself, directly or through other types, through a `switch-on` case or a parse instance, and schemas can import each other. Its fields inside it are read as the type's own fields are. Each instance is read from the input, and so nests only as deeply as the input does: set instances nest at most 256 deep, and a deeper one stops the decode with `Too_Deep`, so that no input can exhaust the stack. Parse instances read from expressions take more stack, and can stop it at a depth that depends on the build. As in Kaitai, `_parent` in a type that contains itself is a different type for each of its instances, so neither the type nor the types in it can refer to the members of the sets that enclose it, other than through `_root` (they can use `_parent._io`), unless a `parent` gives its fields inside it the same `_parent` as its own, as `elf.ksy`'s `next: {type: verdef_section_entry, parent: _parent}` does. In an imported schema, `_root` is the outermost instance of its top-level type, at any depth; a value instance in such a type cannot use it, as it can be evaluated once that instance is no longer decoded. A value instance or parse instance cannot refer to itself through a field of its type, `child.total` in `total`.

Each entry of `imports` names a schema file without its `.ksy`: relative to the directory of the schema that imports it, or, when it starts with `/`, in the first `--import-path` directory that has it. The top-level type of an imported schema is used by its `meta` `id`, and its own `meta` (`endian`, `encoding`) applies inside it. As in Kaitai, it is the `_root` of its own types and has no `_parent`. A schema imported more than once is read once.

A type declared in another type is named by its path, `a::b`, and so is an enum, `a::e` (in an expression, `a::e::v`): the first name is found as any type name is, from the type that names it outward, then among the imported schemas. A type of an imported schema keeps that schema's `meta`. As in Kaitai, a type of another schema used this way has no `_parent`, and neither it nor the types inside it have a `_root`: an expression in them that uses one is `Invalid`, where Kaitai's runtimes fail on a null.

The `meta` of a type, with `endian`, `bit-endian` or `encoding`, applies in the type and in the types declared in it, over the `meta` of the type it is declared in, as in Kaitai. It does not apply in the types it uses that are declared elsewhere.

A type with `params` is given one argument for each, `t(a, b)`, in `type` or in a `switch-on` case. Each argument is an expression of the param's type, evaluated where each instance is read: as in Kaitai, in the stream of the field, after the bytes of a substream, and for a parse instance after it moves to `pos`. Expressions in the type refer to its params by their `id`, and params are not dumped. An integer param holds the argument's value as it is, whatever its integer type, as in the JavaScript runtime, and one with an `enum` takes any integer, where the official compiler requires a value of the enum. A param of a user type takes an instance of that type, read elsewhere (`t(header)`, `t(items[_index])`), whose fields, value instances and parse instances the type can use; a parse instance not read yet is read as it would have been once that instance was read. The argument cannot be an instance of a set that encloses the field, which is still being read, a value instance reached through the param cannot refer to the sets that enclose the argument's instance (through `_parent`), and the param's `_io` is that of the argument's instance. The params of the schema's top-level type take the arguments given to the decoder: `--param`, or `args` of `reader.read` and `reader.read_from_bytes`, one of each param's type (an `i64` for an integer type, a `bool`, `[]byte` for `bytes` or a `string` for `str`), which the tree copies; others are `Invalid_Arguments`. For a user type, the argument is `[]byte`, which the decoder reads, before the root, as an instance of the type in a stream of their own, as a caller of Kaitai's runtimes makes one from bytes (`dcmp_2.ksy`'s `bytes_with_io`): it has no `_parent`, and no `_root` unless it is the top-level type of its schema. Its type cannot have params, which nothing could give.

A `switch-on` case of a type that is not a user type is read as a field of that type, as the official compiler reads it: a `str` or `strz` with the field's `size`, `size-eos`, `terminator` (with `consume`, `include` and `eos-error`) and `pad-right`, and in its schema's `meta` `encoding`, since a `switch-on` field has no `encoding` of its own. An integer, float or bit type ignores the field's `size`, `size-eos` and `terminator`, so only its own bytes are read, whatever the `size`. A `switch-on` field is not a bit type: a bit type chosen leaves its bits over for the next bit type, and the field after it does not start at a byte.

A string's `encoding` is ASCII, UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ISO-8859-1, windows-1251, windows-1252 or IBM437, by any of the names the official compiler knows them by, in any case (`utf-16be`, `cp437`, `latin1`). ASCII and UTF-8 strings are kept as their bytes, so the tree holds a view of the input; the others are decoded into UTF-8, in the tree's arena. `size`, `pad-right` and `terminator` apply to the bytes before they are decoded, as in Kaitai, so a `terminator` or `strz` is one byte even in UTF-16, and a `pad-right: 0` can cut a UTF-16 character in two. A UTF-16 or UTF-32 sequence that is not a character becomes U+FFFD, as in WHATWG's decoders: each unpaired surrogate, and the bytes left at the end that make no code unit. A byte-order mark at the start is kept, as Kaitai's C++ and Python runtimes keep it. ISO-8859-1 is each byte as its code point, and windows-1251 and windows-1252 are WHATWG's tables, which give the bytes the code pages leave undefined their own code points. IBM437 is Python's `cp437`.

A field read once whose `switch-on` matches no case, without a `_` case, is not read, as in Kaitai, unless it has a `size` or `size-eos`: its value is then the bytes of that length, as the official compiler reads them, without `pad-right` removed or cut at a `terminator`. In a repeated `switch-on`, an element that no case chooses, with no `_` case, `size` or `size-eos`, adds no value, as in Kaitai, so the field has fewer values than elements, and `_index` still counts every element. In `repeat-until`, `_` then has no value. An `endian` that is a `switch-on` is evaluated as each instance of its type starts, before its fields are read, as in Kaitai: its expression can use `_root` and `_parent`, and the types declared in the type take the order chosen; one that matches no case, without a `_` case, is `Undecided_Endianness`. `process: zlib` decompresses an element's bytes, once `pad-right` is removed or they are cut at the `terminator`, into the tree's arena: they are the value of a byte array, or the substream that a user type is read from, as in Kaitai, also the bytes of a `switch-on` that chooses no case. Bytes that are not a zlib stream are `Decompression_Failed`. The offset of a value in decompressed bytes is that of its field plus its position in them, as there is none in the file; nothing limits how large the bytes decompress to, as in Kaitai's runtimes. A `switch-on` over a boolean has the cases `true` and `false`. Expressions can refer to a `switch-on` field whose values all have one type: integers of any width, booleans, strings, or the bytes an element no case chooses has. One whose cases are user types or have values of different types cannot be used in expressions, as Kaitai gives it no type that has fields or operators. An array literal with an item that is not a literal is an array, of integers if they are, where the official compiler, which takes a list of byte-sized integers as a byte array, rejects one that cannot be written as bytes (`[n, 2]` with `n` a `u1`). Strings and byte arrays are compared byte by byte, strings as UTF-8 for those that are decoded, and `.length` counts code points, as Kaitai's Python runtime does; its C++ runtime counts bytes, and its JavaScript runtime UTF-16 units, so they agree on ASCII. A string made by `+` or `.to_s` is kept in the tree's arena until the tree is destroyed. Each element read by `repeat: eos` must consume input, and so must each element of `repeat: until` but the last, also an element of a `switch-on` that no case chooses. A `valid` check runs once its value is read, and an expression in it sees the value both as `_` and under the field's name. Since an enum constant is an integer, a `valid` on an integer without an `enum` can compare it with one, where the official compiler requires the `enum`, and `.to_i` of any integer is that integer. `.first`, `.last`, `.min` and `.max` of an empty array fail with `Index_Out_Of_Range`. Sizes are those the official compiler computes from the schema, so an expression can use the size of a later attribute: an attribute's `size` when it is a constant expression (`2 * 4`), else the size of its type or its `contents`, times a constant `repeat-expr`. `if` is ignored. An attribute with any other `repeat`, a `switch-on` (even with a `size`), `size-eos`, or a `terminator` or `strz` and no `size` has no fixed size, and its size is an error. Bit fields add up without alignment, as in that compiler, though they are read with it, so `sizeof` of `b4, u1, b4, u1` is 3, while reading it takes 4 bytes. A value instance is evaluated for the set instance an expression reaches it through (`header.total`), whose `_parent` is the instance that holds it.

Not supported yet: other encodings (such as `UTF-16` without `LE` or `BE`, `ISO-8859-2` or `Shift_JIS`), instances without `pos` or `value` that read bytes, params of other types (`struct`, `io`, `any`), a `parent` other than `_parent`, `_parent._parent` and so on (such as `_root`), an `endian` that is a `switch-on` on the top-level type of the schema decoded, or in a type that contains itself, a `bit-endian` that is a `switch-on`, a `switch-on` field in an expression when its cases are user types or have values of different types, `imports` in a type's `meta`, a cast to a user type of anything but a `switch-on` field read once, or to a type other than an integer or a user type, integer literals above 2^64 - 1 and float literals beyond a 64-bit float, `%` of a float, `?:` of arrays of sets or of arrays, other methods (such as `.to_i(radix)` and `.reverse`), `_sizeof` of a repeated field, and `valid` on a float or with `min` or `max` on a type other than an integer.

`to-string`, which defines how Kaitai's tools show a type's instances, is parsed as an expression and otherwise ignored, as nothing gnrcrdr writes shows it: as in the official compiler, its names are not resolved.

Keys starting with `-` are extensions. The official Kaitai tools ignore them, and gnrcrdr ignores the ones it does not know, as well as `-orig-id` on a type. gnrcrdr's own extensions let `formats/gif89a.ksy` give the same dumps as the SQLite schema it was ported from:

| Extension | Meaning | In standard Kaitai |
|---|---|---|
| `-orig-id: Name` | The name shown in the dump and in error paths, instead of the `id` (on `meta`, the root's name). Expressions still use the `id`. A list of names, as `elf.ksy` gives for the original types of several word sizes, leaves the `id`. | No equivalent; the dump uses the `id`. |
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
python3 tools/kaitai_compare/compare.py --param num_digits=6 --param bits_per_digit=4 --param is_le=false ../kaitai_struct_formats/common/bcd.ksy number.bin
```

A `--param` of a user type is given to the runtime as an instance of the type that its constructor makes from the bytes.

Both decodes are brought to one shape, every field an array of its values, and compared field by field. Parse instances are compared as fields; fields with no values are left out on both sides, as are value instances and params. Names are compared by their ids (an attribute without one by `_unnamed` and its index), so gnrcrdr's `-orig-id` names are mapped back to them, and integers beyond 2^53, which the JavaScript runtime holds as doubles, are compared as doubles. Floats are compared as numbers, as the runtime writes one with an integer value as an integer, and an `f4`, which gnrcrdr writes with the shortest digits that give it, equals the double the runtime widens it to. The runtime reads some negative `s8` values wrongly, as its XOR of the low word is a signed 32-bit one. The JavaScript runtime (0.11.0) moves past a terminator with `include: true` once more than the C++ runtime and gnrcrdr do, so a schema that uses it can differ after it. It decodes strings with `TextDecoder`, which removes a byte-order mark at the start of a UTF-16 string, decodes ISO-8859-1 as windows-1252, and has neither UTF-32 nor IBM437, so strings in those can differ or fail there; its `.length` counts UTF-16 units. The script reads the schemas the schema imports, and gives them to both decoders. With `--offsets` it compares offsets instead of values: those of gnrcrdr's `--offsets` dump, and those the runtime records in debug mode, for every value that is not a set instance. The script exits 1 if any file differs or fails to decode. Run it when the decoder, the `.ksy` compiler or `formats/gif.ksy` changes.

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
