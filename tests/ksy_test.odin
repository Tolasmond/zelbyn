package tests

import dmp "../gnrcrdr/dump"
import ksy "../gnrcrdr/ksy"
import mdat "../gnrcrdr/metadata"
import "core:fmt"
import "core:strings"
import "core:testing"

// The start of most test schemas: a top level with meta and endian le.
@(private = "file")
HEAD :: "meta:\n  id: t\n  endian: le\n"

@(private = "file")
Ksy_Error_Case :: struct {
	src:          string,
	kind:         ksy.Error_Kind,
	line, column: int,
	message:      string, // must occur in the error's message
}

@(private = "file")
KSY_ERROR_CASES := [?]Ksy_Error_Case {
	// YAML outside the subset, and duplicate keys
	{HEAD + "seq:\n  - id: a\n    type: &x u1\n", .Unsupported, 6, 11, "anchors"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    type: u2\n", .Invalid, 7, 5, `duplicate key "type" (first at line 6, column 5)`},
	{"meta: [\n", .Syntax, 2, 1, "unterminated flow collection"},

	// keys: Kaitai keys outside the subset, unknown keys, misplaced extensions
	{HEAD + "seq:\n  - id: a\n    type: u1\n    pos: 1\n", .Unsupported, 7, 5, "attribute a: pos is not supported"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    process: xor(1)\n", .Unsupported, 7, 5, "process is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    terminator: 0\n", .Unsupported, 7, 5, "terminator is not supported"},
	{HEAD + "seq:\n  - id: a\n    size-eos: true\n", .Unsupported, 6, 5, "size-eos is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    sizee: 1\n", .Invalid, 7, 5, `attribute a: unknown key "sizee"`},
	{HEAD + "params:\n  - id: p\n", .Unsupported, 4, 1, "params is not supported"},
	{HEAD + "sequence: []\n", .Invalid, 4, 1, `the top level: unknown key "sequence"`},
	{"meta:\n  id: t\n  ks-version: 0.9\n", .Unsupported, 3, 3, "meta: ks-version is not supported"},
	{"meta:\n  id: t\n  imports: [a]\n", .Unsupported, 3, 3, "meta: imports is not supported"},
	{"meta:\n  id: t\n  name: x\n", .Invalid, 3, 3, `meta: unknown key "name"`},
	{"meta:\n  id: t\n  -peek: [1]\n", .Invalid, 3, 3, "the extension -peek does not apply here"},
	{HEAD + "types:\n  u:\n    meta:\n      endian: be\n", .Unsupported, 6, 5, "type u: meta in a type is not supported"},
	{HEAD + "types:\n  unused:\n    seq:\n      - id: a\n        type: u1\n        pos: 0\n", .Unsupported, 9, 9, "attribute a: pos is not supported"},
	{HEAD + "types:\n  unused:\n    instances:\n      x:\n        pos: 0\n        type: u1\n", .Unsupported, 8, 9, "instance x: pos is not supported"},

	// the top level and meta
	{"# nothing\n", .Invalid, 0, 0, "the schema is empty"},
	{"seq: []\n", .Invalid, 1, 1, "the schema has no meta"},
	{"meta:\n  title: t\n", .Invalid, 2, 3, "meta has no id"},
	{"meta:\n  id: T\n", .Invalid, 2, 7, `meta id "T" is not an identifier`},
	{"meta:\n  id: t\n  endian: little\n", .Invalid, 3, 11, `endian must be le or be, not "little"`},
	{"meta:\n  id: t\n  endian:\n    switch-on: x\n", .Unsupported, 4, 5, "endian: switch-on is not supported"},
	{"meta:\n  id: t\n  encoding: UTF-16LE\n", .Unsupported, 3, 13, `encoding "UTF-16LE" is not supported`},

	// attributes
	{HEAD + "seq:\n  - type: u1\n", .Unsupported, 5, 5, "an attribute in type t has no id"},
	{HEAD + "seq:\n  - id: A\n    type: u1\n", .Invalid, 5, 9, `id "A" is not an identifier`},
	{HEAD + "seq:\n  - id: a\n    type: u1\n  - id: a\n    type: u1\n", .Invalid, 7, 9, "id a is already used (line 5, column 9)"},
	{HEAD + "seq:\n  - id: a\n", .Invalid, 5, 5, "a needs a type, a size or contents"},

	// types
	{HEAD + "seq:\n  - id: a\n    type: u3\n", .Invalid, 6, 11, "a: unknown type u3"},
	{HEAD + "seq:\n  - id: a\n    type: u1le\n", .Invalid, 6, 11, "a: unknown type u1le"},
	{"meta:\n  id: t\nseq:\n  - id: a\n    type: u2\n", .Invalid, 5, 11, "a: u2 needs le or be, or meta endian"},
	{HEAD + "seq:\n  - id: a\n    type: strz\n    encoding: ASCII\n", .Unsupported, 6, 11, "a: type strz is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: b3\n", .Unsupported, 6, 11, "a: type b3 is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    encoding: ASCII\n", .Unsupported, 6, 11, "a: str without size is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    size: 1\n", .Invalid, 6, 11, "a: str needs an encoding"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    encoding: ASCII\n", .Invalid, 7, 5, "a: encoding applies only to str"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    size: 2\n", .Invalid, 7, 5, "a: size does not apply to u1"},
	{HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    seq:\n      - id: b\n        type: s\n", .Unsupported, 9, 5, "type s contains itself"},
	{HEAD + "seq:\n  - id: a\n    contents: [1]\n    type: u1\n", .Invalid, 7, 5, "a: contents cannot have a type"},
	{HEAD + "seq:\n  - id: a\n    contents: 1\n", .Invalid, 6, 15, "contents: write a byte as a sequence, [1]"},
	{HEAD + "seq:\n  - id: a\n    contents: [256]\n", .Invalid, 6, 16, "contents: 256 is not a byte"},

	// counts
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat: forever\n", .Invalid, 7, 13, `a: repeat must be expr, eos or until, not "forever"`},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat: until\n", .Invalid, 7, 5, "a: repeat: until needs repeat-until"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat-until: _ == 0\n", .Invalid, 7, 5, "a: repeat-until needs repeat: until"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat: eos\n    repeat-expr: 2\n", .Invalid, 8, 5, "a: repeat-expr needs repeat: expr"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat: expr\n", .Invalid, 7, 5, "a: repeat: expr needs repeat-expr"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat-expr: 2\n", .Invalid, 7, 5, "a: repeat-expr needs repeat: expr"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    repeat: until\n    repeat-until: _ + 1\n", .Invalid, 8, 21, "repeat-until: expected a boolean, found an integer"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    repeat: until\n    repeat-until: _.c == 0\ntypes:\n  s:\n    seq:\n      - id: b\n        type: u1\n", .Invalid, 8, 21, "repeat-until: a has no field c"},
	{HEAD + "seq:\n  - id: a\n    size: _\n", .Invalid, 6, 11, "size: _ is only defined in repeat-until"},

	// if and enum
	{HEAD + "seq:\n  - id: a\n    type: u1\n    if: 1\n", .Invalid, 7, 9, "if: expected a boolean, found an integer"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    if: a == 1\n", .Invalid, 7, 9, "if: t has no field a"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    enum: e\n", .Invalid, 7, 11, "a: no enum e"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    enum: e\nenums:\n  e:\n    1: x\n", .Invalid, 7, 5, "a: enum applies only to integer types"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    enum: s::e\n", .Unsupported, 7, 11, "an enum of another type (s::e) is not supported"},

	// switch-on
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n", .Invalid, 7, 7, "a: switch-on needs cases"},
	{HEAD + "seq:\n  - id: a\n    type:\n      cases: {}\n", .Invalid, 7, 7, "a: a type mapping needs switch-on"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases: {}\n      default: x\n", .Invalid, 9, 7, `a: type: unknown key "default"`},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1 == 1\n      cases: {}\n", .Invalid, 7, 20, "switch-on: expected an integer, found a boolean"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n", .Unsupported, 9, 12, "a: a case of type u1 is not supported"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: nope\n", .Invalid, 9, 12, "a: unknown type nope"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        n: s\ntypes:\n  s: {}\n", .Unsupported, 11, 9, "a case must be an integer or an enum constant"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: s\n        0x1: s\ntypes:\n  s: {}\n", .Invalid, 10, 9, "a: case 1 is already given (line 9, column 9)"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: s\n    size: 2\ntypes:\n  s: {}\n", .Unsupported, 10, 5, "a: size on a switch-on field is not supported"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: s\n    repeat: expr\n    repeat-expr: 2\ntypes:\n  s: {}\n", .Unsupported, 7, 18, "a repeated switch-on without a _ case is not supported"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        _: s\n  - id: b\n    size: a.c\ntypes:\n  s:\n    seq:\n      - id: c\n        type: u1\n", .Unsupported, 11, 11, "size: a is a switch-on field; it cannot be used in expressions"},

	// instances: value instances only, over their own type
	{HEAD + "instances:\n  x:\n    doc: d\n", .Unsupported, 5, 3, "instance x: only value instances are supported"},
	{HEAD + "instances:\n  x:\n    value: y\n  y:\n    value: x + 1\n", .Invalid, 6, 12, "value instance x refers to itself"},
	{HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  a:\n    value: 1\n", .Invalid, 8, 3, "id a is already used (line 5, column 9)"},
	{HEAD + "seq:\n  - id: b\n    size: 1\ninstances:\n  x:\n    value: b\n", .Unsupported, 9, 12, "value instance x: only integer and boolean values are supported"},
	{HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    instances:\n      x:\n        value: _parent.y\n", .Unsupported, 11, 16, "_parent in a value instance is not supported"},
	{HEAD + "instances:\n  x:\n    value: _io.pos\n", .Unsupported, 6, 12, "_io in a value instance is not supported"},
	{HEAD + "seq:\n  - id: a\n    size: x\n  - id: n\n    type: u1\ninstances:\n  x:\n    value: n\n", .Invalid, 11, 12, "value: t has no field n"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    -peek: [1]\n    -until-peek: [0]\ntypes:\n  s: {}\n", .Invalid, 8, 5, "-until-peek cannot be combined with -peek"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    repeat: expr\n    repeat-expr: 2\n    -while-peek: [1]\ntypes:\n  s: {}\n", .Invalid, 9, 5, "-while-peek cannot be combined with repeat"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    -while-peek: [1, 2]\ntypes:\n  s: {}\n", .Unsupported, 7, 18, "-while-peek with more than one byte"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    -peek: []\ntypes:\n  s: {}\n", .Invalid, 7, 12, "-peek needs at least one byte"},

	// expressions: the column is that of the character at fault
	{HEAD + "seq:\n  - id: a\n    size: 1 +\n", .Syntax, 6, 14, "size: unexpected end of expression"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    size: n + m\n", .Invalid, 8, 15, "size: t has no field m"},
	{HEAD + "seq:\n  - id: a\n    size: later\n  - id: later\n    type: u1\n", .Invalid, 6, 11, "size: t has no field later"},
	{HEAD + "seq:\n  - id: a\n    size: 'e::x'\nenums:\n  e:\n    1: y\n", .Invalid, 6, 12, "enum e has no value x"},

	// valid
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: 256\n", .Invalid, 7, 12, "a: 256 does not fit in a UInt8"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: x + 1\n", .Unsupported, 7, 12, "must be an integer literal"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    size: 1\n    encoding: ASCII\n    valid: G\n", .Unsupported, 9, 12, "must be a string literal"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      min: 2\n      max: 1\n", .Invalid, 8, 7, "a: min is above max"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      eq: 1\n      min: 0\n", .Invalid, 8, 7, "exactly one of eq, min and max, or any-of"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      expr: _ > 1\n", .Unsupported, 8, 7, "a: valid: expr is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: f4\n    valid: 1\n", .Unsupported, 7, 12, "valid on a Float32"},

	// -bits
	{HEAD + "seq:\n  - id: a\n    size: 1\n    -bits:\n      - {id: b, low: 0, high: 0}\n", .Invalid, 8, 7, "a: -bits applies only to integer types"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: b, low: 4, high: 8}\n", .Invalid, 8, 9, "b has bits 4 to 8, not within 0 to 7"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: a, low: 0, high: 0}\n", .Invalid, 8, 14, "id a is already used"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: b, low: 0}\n", .Invalid, 8, 9, "a: a -bits entry has no high"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: b, low: 0, high: 0, width: 1}\n", .Invalid, 8, 34, `-bits: unknown key "width"`},

	// enums
	{HEAD + "enums:\n  e:\n    1:\n      id: one\n      doc: d\n", .Unsupported, 7, 7, "values with id and doc are not supported"},
	{HEAD + "enums:\n  e:\n    one: 1\n", .Invalid, 6, 5, `enum e: "one" is not an integer`},
	{HEAD + "enums:\n  e:\n    1: x\n    0x01: y\n", .Invalid, 7, 5, "enum e: value 0x01 appears twice"},
}

@(test)
ksy_errors :: proc(t: ^testing.T) {
	for c in KSY_ERROR_CASES {
		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		err := ksy.compile(c.src, &ff)
		defer ksy.destroy_error(&err)

		testing.expectf(
			t,
			err.kind == c.kind && err.line == c.line && err.column == c.column && strings.contains(err.message, c.message),
			"%q:\n  got  %v at %v:%v: %s\n  want %v at %v:%v: ...%s...",
			c.src, err.kind, err.line, err.column, err.message, c.kind, c.line, c.column, c.message)
	}
}

// Compiles src, decodes input with it and returns the text dump (in
// context.temp_allocator), or "error: <kind> at <offset> in <path>".
@(private = "file")
ksy_dump :: proc(t: ^testing.T, src: string, input: []byte) -> string {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return ""

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, input, &d)
	if d.err.kind != .None do return fmt.tprintf("error: %v at %v in %s", d.err.kind, d.err.offset, d.err.path)

	b := strings.builder_make(context.temp_allocator)
	werr := dmp.write_text(strings.to_writer(&b), &ff, &d.tree)
	testing.expectf(t, werr == .None, "dump: %v", werr)
	return strings.to_string(b)
}

@(private = "file")
expect_dump :: proc(t: ^testing.T, name, got, want: string, loc := #caller_location) {
	testing.expectf(t, got == want, "%s:\ngot:\n%s\nwant:\n%s", name, got, want, loc = loc)
}

@(test)
ksy_extensions :: proc(t: ^testing.T) {
	// -orig-id names the root and fields in the dump; -while-peek repeats
	// while the next byte is 1 and -until-peek until it is 0, neither
	// consuming it; -peek reads a field only when the bytes match
	src := `meta:
  id: t
  -orig-id: Top
seq:
  - id: items
    -orig-id: Item List
    type: item
    -while-peek: [1]
  - id: tail
    type: tail
    -peek: [0x02, 0x03]
  - id: missing
    type: tail
    -peek: [0x02, 0x03]
  - id: runs
    type: run
    -until-peek: [0]
  - id: end
    type: u1
types:
  item:
    seq:
      - id: tag
        type: u1
      - id: v
        -orig-id: Value
        type: u1
  tail:
    seq:
      - id: magic
        contents: [2, 3]
  run:
    seq:
      - id: b
        type: u1
`
	expect_dump(t, "extensions", ksy_dump(t, src, {1, 10, 1, 11, 2, 3, 7, 8, 0}), `Top[0].Item List[0].tag[0] = 1
Top[0].Item List[0].Value[0] = 10
Top[0].Item List[1].tag[0] = 1
Top[0].Item List[1].Value[0] = 11
Top[0].tail[0].magic[0] = <2 bytes> 02 03
Top[0].runs[0].b[0] = 7
Top[0].runs[1].b[0] = 8
Top[0].end[0] = 0
`)

	// -until-peek needs its terminator; -while-peek stops at the end
	expect_dump(t, "no terminator", ksy_dump(t, src, {1, 10, 7}), "error: Unexpected_EOF at 3 in Top[0]")

	// -bits: unsigned subfields in order of their low bit, after their integer
	bits := HEAD + `seq:
  - id: p
    type: u2
    -bits:
      - id: top
        -orig-id: Top Bits
        low: 12
        high: 15
      - id: low
        low: 0
        high: 3
`
	expect_dump(t, "bits", ksy_dump(t, bits, {0x34, 0xa2}), `t[0].p[0] = 41524
t[0].low[0] = 4
t[0].Top Bits[0] = 10
`)
}

@(test)
ksy_types_and_values :: proc(t: ^testing.T) {
	// byte order from meta and from suffixes; str keeps NUL bytes (§7.3);
	// a literal count on a primitive; sizes from fields, _parent and enums
	src := `meta:
  id: t
  endian: be
  encoding: ASCII
seq:
  - id: a
    type: u2
  - id: b
    type: u2le
  - id: s
    type: str
    size: 4
  - id: f
    type: s1
    repeat: expr
    repeat-expr: 2
  - id: n
    type: u1
  - id: inner
    type: inner
  - id: k
    size: kinds::two
enums:
  kinds:
    1: one
    2: two
types:
  inner:
    seq:
      - id: data
        size: _parent.n - 1
`
	input := []byte{0x12, 0x34, 0x12, 0x34, 'a', 0, 'b', 0, 0xff, 0x01, 3, 0xaa, 0xbb, 0xcc, 0xdd}
	expect_dump(t, "types", ksy_dump(t, src, input), `t[0].a[0] = 4660
t[0].b[0] = 13330
t[0].s[0] = "a\x00b\x00"
t[0].f[0] = -1
t[0].f[1] = 1
t[0].n[0] = 3
t[0].inner[0].data[0] = <2 bytes> aa bb
t[0].k[0] = <2 bytes> cc dd
`)

	// valid and contents fail with the value's path
	checks := HEAD + `seq:
  - id: magic
    contents: GI
  - id: x
    type: u1
    valid:
      min: 1
      max: 9
  - id: y
    type: u1
    valid:
      any-of: [3, 5]
  - id: z
    type: s2
    valid: -2
`
	expect_dump(t, "checks pass", ksy_dump(t, checks, {'G', 'I', 9, 5, 0xfe, 0xff}), `t[0].magic[0] = <2 bytes> 47 49
t[0].x[0] = 9
t[0].y[0] = 5
t[0].z[0] = -2
`)
	expect_dump(t, "contents", ksy_dump(t, checks, {'G', 'X', 9, 5, 0xfe, 0xff}), "error: Not_Equal at 0 in t[0].magic[0]")
	expect_dump(t, "max", ksy_dump(t, checks, {'G', 'I', 10, 5, 0xfe, 0xff}), "error: Greater_Than_Max at 2 in t[0].x[0]")
	expect_dump(t, "any-of", ksy_dump(t, checks, {'G', 'I', 9, 4, 0xfe, 0xff}), "error: Not_Any_Of at 3 in t[0].y[0]")
	expect_dump(t, "eq", ksy_dump(t, checks, {'G', 'I', 9, 5, 0xfd, 0xff}), "error: Not_Equal at 4 in t[0].z[0]")

	// - keys gnrcrdr does not know are ignored, as the official tools do
	expect_dump(t, "unknown extension", ksy_dump(t, HEAD + "-webide-representation: x\nseq:\n  - id: a\n    type: u1\n    -note: y\n", {7}), "t[0].a[0] = 7\n")

	// -orig-id on a type documents its original name, as in
	// kaitai_struct_formats; nothing shows it
	expect_dump(t, "-orig-id on a type", ksy_dump(t, HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    -orig-id: S\n    seq:\n      - id: b\n        type: u1\n", {7}), "t[0].a[0].b[0] = 7\n")
}

@(test)
ksy_kaitai_features :: proc(t: ^testing.T) {
	// if, value instances (Bool and Int, one referring to a later one, used
	// in the type and from outside it), a substream read with repeat: eos,
	// repeat: until over _ and _io.eof, enum, and switch-on whose cases are
	// enum constants and an integer, with no case for stop
	src := HEAD + `seq:
  - id: hdr
    type: hdr
  - id: opt
    type: u1
    if: hdr.has_opt
  - id: skipped
    type: u1
    if: not hdr.has_opt
  - id: table
    type: table
    size: hdr.count * 2
  - id: blocks
    type: block
    repeat: until
    repeat-until: _io.eof or _.kind == kind::stop
types:
  hdr:
    seq:
      - id: flags
        type: u1
    instances:
      has_opt:
        value: (flags & 1) != 0
      count:
        value: double_count >> 1
      double_count:
        value: (flags >> 4) * 2
  table:
    seq:
      - id: entries
        type: u2
        repeat: eos
  block:
    seq:
      - id: kind
        type: u1
        enum: kind
      - id: body
        type:
          switch-on: kind
          cases:
            'kind::one': one
            2: two
  one:
    seq:
      - id: v
        type: u1
  two:
    seq:
      - id: v
        type: u2
enums:
  kind:
    1: one
    2: two
    9: stop
`
	expect_dump(t, "until stop", ksy_dump(t, src, {0x21, 7, 1, 0, 2, 0, 1, 0xaa, 2, 0xbb, 0xcc, 9}), `t[0].hdr[0].flags[0] = 33
t[0].opt[0] = 7
t[0].table[0].entries[0] = 1
t[0].table[0].entries[1] = 2
t[0].blocks[0].kind[0] = 1
t[0].blocks[0].body[0].v[0] = 170
t[0].blocks[1].kind[0] = 2
t[0].blocks[1].body[0].v[0] = 52411
t[0].blocks[2].kind[0] = 9
`)
	expect_dump(t, "until eof", ksy_dump(t, src, {0x10, 3, 4, 0, 1, 5}), `t[0].hdr[0].flags[0] = 16
t[0].skipped[0] = 3
t[0].table[0].entries[0] = 4
t[0].blocks[0].kind[0] = 1
t[0].blocks[0].body[0].v[0] = 5
`)
	expect_dump(t, "until past the end", ksy_dump(t, src, {0x10, 3, 4, 0, 2, 5}), "error: Unexpected_EOF at 5 in t[0].blocks[0].body[0].v[0]")

	// a substream: _io is the substream, its unread bytes are skipped, and
	// errors in it give offsets in the input
	sub := HEAD + `seq:
  - id: len
    type: u1
  - id: sub
    type: sub
    size: len
  - id: after
    type: u1
types:
  sub:
    seq:
      - id: a
        type: u1
      - id: rest
        size: _io.size - _io.pos - 1
      - id: wide
        type: u2
        if: _io.size == 2
`
	expect_dump(t, "substream", ksy_dump(t, sub, {4, 10, 20, 30, 40, 99}), `t[0].len[0] = 4
t[0].sub[0].a[0] = 10
t[0].sub[0].rest[0] = <2 bytes> 14 1e
t[0].after[0] = 99
`)
	expect_dump(t, "substream end", ksy_dump(t, sub, {2, 10, 20, 30, 99}), "error: Unexpected_EOF at 2 in t[0].sub[0].wide[0]")
	expect_dump(t, "substream too long", ksy_dump(t, sub, {5, 10, 20}), "error: Unexpected_EOF at 1 in t[0].sub[0]")

	// every count on primitives: an expression, -peek, repeat: eos and
	// repeat: until over _
	counts := HEAD + `seq:
  - id: n
    type: u1
  - id: v
    type: u1
    repeat: expr
    repeat-expr: n
  - id: z
    type: u1
    repeat: until
    repeat-until: _ == 0
  - id: m
    type: u1
    -peek: [0xff]
  - id: rest
    type: u1
    repeat: eos
`
	expect_dump(t, "counts", ksy_dump(t, counts, {2, 5, 6, 3, 0, 0xff, 8, 9}), `t[0].n[0] = 2
t[0].v[0] = 5
t[0].v[1] = 6
t[0].z[0] = 3
t[0].z[1] = 0
t[0].m[0] = 255
t[0].rest[0] = 8
t[0].rest[1] = 9
`)

	// a repeated switch-on on _index, with a _ case
	switched := HEAD + `seq:
  - id: items
    type:
      switch-on: _index
      cases:
        0: one
        _: two
    repeat: expr
    repeat-expr: 2
types:
  one:
    seq:
      - id: v
        type: u1
  two:
    seq:
      - id: w
        type: u2
`
	expect_dump(t, "default case", ksy_dump(t, switched, {1, 2, 3}), `t[0].items[0].v[0] = 1
t[0].items[1].w[0] = 770
`)

	// repeat: eos and repeat: until stop an element that consumes nothing
	empty := HEAD + "seq:\n  - id: e\n    type: empty\n    repeat: eos\ntypes:\n  empty: {}\n"
	expect_dump(t, "eos without progress", ksy_dump(t, empty, {1}), "error: No_Progress at 0 in t[0].e[0]")
	empty_until := HEAD + "seq:\n  - id: e\n    type: empty\n    repeat: until\n    repeat-until: _io.eof\ntypes:\n  empty: {}\n"
	expect_dump(t, "until without progress", ksy_dump(t, empty_until, {1}), "error: No_Progress at 0 in t[0].e[0]")
}
