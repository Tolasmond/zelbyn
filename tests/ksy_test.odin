package tests

import dmp "../gnrcrdr/dump"
import fld "../gnrcrdr/field"
import ksy "../gnrcrdr/ksy"
import mdat "../gnrcrdr/metadata"
import rdr "../gnrcrdr/reader"
import "core:fmt"
import "core:slice"
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
	{HEAD + "seq:\n  - id: a\n    size: 1\n    io: _root._io\n", .Unsupported, 7, 5, "attribute a: io is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    sizee: 1\n", .Invalid, 7, 5, `attribute a: unknown key "sizee"`},
	{HEAD + "params:\n  - id: p\n    type: u1\n", .Unsupported, 4, 1, "params on the top-level type are not supported, except in an imported schema"},
	{HEAD + "sequence: []\n", .Invalid, 4, 1, `the top level: unknown key "sequence"`},
	{"meta:\n  id: t\n  imports: a\n", .Invalid, 3, 12, "imports must be a sequence"},
	{"meta:\n  id: t\n  imports: ['']\n", .Invalid, 3, 13, "imports: an import is empty"},
	{"meta:\n  id: t\n  imports: [/common/x]\n", .Invalid, 3, 13, "imports: /common/x is in none of the import paths"},
	{"meta:\n  id: t\n  imports: [tests/schemas/imports/does_not_exist]\n", .Invalid, 3, 13, "imports: cannot read tests/schemas/imports/does_not_exist.ksy"},
	{"meta:\n  id: t\n  ks-debug: true\n", .Unsupported, 3, 3, "meta: ks-debug is not supported"},
	{"meta:\n  id: t\n  name: x\n", .Invalid, 3, 3, `meta: unknown key "name"`},
	{"meta:\n  id: t\n  -peek: [1]\n", .Invalid, 3, 3, "the extension -peek does not apply here"},
	{HEAD + "types:\n  unused:\n    seq:\n      - id: a\n        type: u1\n        pos: 0\n", .Unsupported, 9, 9, "attribute a: pos is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    io: _root._io\n", .Unsupported, 7, 5, "attribute a: io is not supported"},
	{HEAD + "instances:\n  x:\n    pos: 0\n    type: u1\n    io: 1\n", .Invalid, 8, 9, "io: expected a stream, found an integer"},
	{HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  x:\n    pos: 0\n    type: u1\n    io: a._io\n", .Invalid, 11, 11, "io: an integer has no _io"},

	// the top level and meta
	{"# nothing\n", .Invalid, 0, 0, "the schema is empty"},
	{"seq: []\n", .Invalid, 1, 1, "the schema has no meta"},
	{"meta:\n  title: t\n", .Invalid, 2, 3, "meta has no id"},
	{"meta:\n  id: T\n", .Invalid, 2, 7, `meta id "T" is not an identifier`},
	{"meta:\n  id: t\n  endian: little\n", .Invalid, 3, 11, `endian must be le or be, not "little"`},
	{"meta:\n  id: t\n  endian:\n    switch-on: x\n", .Unsupported, 4, 5, "endian: switch-on is not supported"},
	{"meta:\n  id: t\n  encoding: UTF-16LE\n", .Unsupported, 3, 13, `encoding "UTF-16LE" is not supported`},
	{"meta:\n  id: t\n  ks-version: 0.12\n", .Unsupported, 3, 15, "ks-version 0.12 is newer than 0.11, the Kaitai version gnrcrdr follows"},
	{"meta:\n  id: t\n  ks-version: 0.11.1\n", .Unsupported, 3, 15, "ks-version 0.11.1 is newer than 0.11"},
	{"meta:\n  id: t\n  ks-version: 1\n", .Unsupported, 3, 15, "ks-version 1 is newer than 0.11"},
	{"meta:\n  id: t\n  ks-version: 0.9.\n", .Invalid, 3, 15, `ks-version "0.9." is not a version`},
	{"meta:\n  id: t\n  ks-version: 0..9\n", .Invalid, 3, 15, `ks-version "0..9" is not a version`},
	{"meta:\n  id: t\n  ks-version: 0.9.1.2\n", .Invalid, 3, 15, `ks-version "0.9.1.2" is not a version`},
	{"meta:\n  id: t\n  ks-version: v0.9\n", .Invalid, 3, 15, `ks-version "v0.9" is not a version`},
	{"meta:\n  id: t\n  ks-version: ''\n", .Invalid, 3, 15, `ks-version "" is not a version`},
	{"meta:\n  id: t\n  ks-version: 99999999999999999999.0\n", .Invalid, 3, 15, "is not a version"},
	{"meta:\n  id: t\n  ks-version: [0, 9]\n", .Invalid, 3, 15, "ks-version must be a scalar"},

	// meta in a type: the keys of the schema's meta, and the types declared
	// in the type inherit it, but not the types it uses (w)
	{HEAD + "types:\n  u:\n    meta: 1\n", .Invalid, 6, 11, "meta must be a mapping"},
	{HEAD + "types:\n  u:\n    meta:\n      name: x\n", .Invalid, 7, 7, `type u: meta: unknown key "name"`},
	{HEAD + "types:\n  u:\n    meta:\n      ks-debug: true\n", .Unsupported, 7, 7, "type u: meta: ks-debug is not supported"},
	{HEAD + "types:\n  u:\n    meta:\n      imports: [x]\n", .Unsupported, 7, 7, "type u: imports in a type are not supported"},
	{HEAD + "types:\n  u:\n    meta:\n      id: U\n", .Invalid, 7, 11, `meta id "U" is not an identifier`},
	{HEAD + "types:\n  u:\n    meta:\n      endian:\n        switch-on: x\n", .Unsupported, 8, 9, "endian: switch-on is not supported"},
	{HEAD + "types:\n  u:\n    meta:\n      encoding: UTF-16LE\n", .Unsupported, 7, 17, `encoding "UTF-16LE" is not supported`},
	{HEAD + "types:\n  u:\n    meta:\n      ks-version: 0.12\n", .Unsupported, 7, 19, "ks-version 0.12 is newer than 0.11"},
	{"meta:\n  id: t\nseq:\n  - id: a\n    type: u\ntypes:\n  u:\n    meta:\n      encoding: ASCII\n    seq:\n      - id: b\n        type: w\n  w:\n    seq:\n      - id: s\n        type: strz\n", .Invalid, 16, 15, "s: str needs an encoding, or meta encoding"},

	// attributes
	{HEAD + "seq:\n  - type: u1\n", .Unsupported, 5, 5, "an attribute in type t has no id"},
	{HEAD + "seq:\n  - id: A\n    type: u1\n", .Invalid, 5, 9, `id "A" is not an identifier`},
	{HEAD + "seq:\n  - id: a\n    type: u1\n  - id: a\n    type: u1\n", .Invalid, 7, 9, "id a is already used (line 5, column 9)"},
	{HEAD + "seq:\n  - id: a\n", .Invalid, 5, 5, "a needs a type, size, size-eos, terminator or contents"},
	{HEAD + "seq:\n  - id: a\n    size-eos: false\n", .Invalid, 5, 5, "a needs a type, size, size-eos, terminator or contents"},

	// types
	{HEAD + "seq:\n  - id: a\n    type: u3\n", .Invalid, 6, 11, "a: unknown type u3"},
	{HEAD + "seq:\n  - id: a\n    type: u1le\n", .Invalid, 6, 11, "a: unknown type u1le"},
	{"meta:\n  id: t\nseq:\n  - id: a\n    type: u2\n", .Invalid, 5, 11, "a: u2 needs le or be, or meta endian"},
	{HEAD + "seq:\n  - id: a\n    type: b65\n", .Invalid, 6, 11, "a: unknown type b65"},
	{HEAD + "seq:\n  - id: a\n    type: b01\n", .Invalid, 6, 11, "a: unknown type b01"},
	{HEAD + "seq:\n  - id: a\n    type: b4\n    size: 1\n", .Invalid, 7, 5, "a: size does not apply to b4"},
	{HEAD + "seq:\n  - id: a\n    type: b1\n    valid:\n      min: false\n", .Unsupported, 8, 7, "a: min and max are only supported on integer types"},
	{"meta:\n  id: t\n  bit-endian: x\n", .Invalid, 3, 15, "bit-endian must be le or be"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    encoding: ASCII\n", .Invalid, 6, 11, "a: str needs size, size-eos or terminator"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    size: 1\n", .Invalid, 6, 11, "a: str needs an encoding"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    encoding: ASCII\n", .Invalid, 7, 5, "a: encoding applies only to str"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    size: 2\n", .Invalid, 7, 5, "a: size does not apply to u1"},
	{HEAD + "seq:\n  - id: a\n    contents: [1]\n    type: u1\n", .Invalid, 7, 5, "a: contents cannot have a type"},

	// size-eos
	{HEAD + "seq:\n  - id: a\n    size: 1\n    size-eos: true\n", .Invalid, 7, 5, "a: size and size-eos cannot both be given"},
	{HEAD + "seq:\n  - id: a\n    size-eos: yes\n", .Invalid, 6, 15, `size-eos must be true or false, not "yes"`},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    size-eos: true\n", .Invalid, 7, 5, "a: size-eos does not apply to u1"},
	{HEAD + "seq:\n  - id: a\n    contents: [1]\n    size-eos: true\n", .Invalid, 7, 5, "a: contents cannot have size-eos"},
	{HEAD + "seq:\n  - id: a\n    contents: 1\n", .Invalid, 6, 15, "contents: write a byte as a sequence, [1]"},
	{HEAD + "seq:\n  - id: a\n    contents: [256]\n", .Invalid, 6, 16, "contents: 256 is not a byte"},

	// terminator and pad-right
	{HEAD + "seq:\n  - id: a\n    terminator: 256\n", .Invalid, 6, 17, `a: terminator must be a byte, 0 to 255, not "256"`},
	{HEAD + "seq:\n  - id: a\n    terminator: '0'\n", .Invalid, 6, 17, `a: terminator must be a byte, 0 to 255, not "0"`},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    terminator: 0\n", .Invalid, 7, 5, "a: terminator does not apply to u1"},
	{HEAD + "seq:\n  - id: a\n    contents: [1]\n    pad-right: 0\n", .Invalid, 7, 5, "a: contents cannot have pad-right"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    consume: false\n", .Invalid, 7, 5, "a: consume applies only with terminator or strz"},
	{HEAD + "seq:\n  - id: a\n    size: 2\n    terminator: 0\n    eos-error: false\n", .Invalid, 8, 5, "a: eos-error does not apply with a size"},
	{HEAD + "seq:\n  - id: a\n    terminator: 0\n    include: maybe\n", .Invalid, 7, 14, `include must be true or false, not "maybe"`},
	{HEAD + "seq:\n  - id: a\n    terminator: 0\n    pad-right: 0\n", .Invalid, 7, 5, "a: pad-right needs size or size-eos"},

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
	{HEAD + "seq:\n  - id: a\n    type: u1\n    if: a == 1\n", .Invalid, 7, 9, "if: a cannot be used in its own if or repeat-expr"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    enum: e\n", .Invalid, 7, 11, "a: no enum e"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    enum: e\nenums:\n  e:\n    1: x\n", .Invalid, 7, 5, "a: enum applies only to integer types"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    enum: s::e\n", .Unsupported, 7, 11, "an enum of another type (s::e) is not supported"},

	// switch-on
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n", .Invalid, 7, 7, "a: switch-on needs cases"},
	{HEAD + "seq:\n  - id: a\n    type:\n      cases: {}\n", .Invalid, 7, 7, "a: a type mapping needs switch-on"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases: {}\n      default: x\n", .Invalid, 9, 7, `a: type: unknown key "default"`},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1 == 1\n      cases: {}\n", .Unsupported, 7, 18, "a: switch-on over a boolean is not supported"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: str\n", .Invalid, 9, 12, "a: str needs size, size-eos or terminator"},
	{"meta:\n  id: t\nseq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: u2\n", .Invalid, 8, 12, "a: u2 needs le or be, or meta endian"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    type:\n      switch-on: 1\n      cases:\n        1: strz\n", .Invalid, 10, 12, "a: a case of type strz needs meta encoding"},
	{HEAD + "  encoding: ASCII\nseq:\n  - id: a\n    size: 1\n    encoding: ASCII\n    type:\n      switch-on: 1\n      cases:\n        1: strz\n", .Invalid, 8, 5, "a: encoding applies only to str"},
	{HEAD + "seq:\n  - id: a\n    consume: false\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n", .Invalid, 6, 5, "a: consume applies only with terminator or strz"},
	{HEAD + "  encoding: ASCII\nseq:\n  - id: a\n    size: 2\n    consume: false\n    type:\n      switch-on: 1\n      cases:\n        1: strz\n", .Invalid, 8, 5, "a: consume does not apply with a size"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: nope\n", .Invalid, 9, 12, "a: unknown type nope"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        n: s\ntypes:\n  s: {}\n", .Unsupported, 11, 9, "a case must be an integer or an enum constant"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: s\n        0x1: s\ntypes:\n  s: {}\n", .Invalid, 10, 9, "a: case 1 is already given (line 9, column 9)"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: s\n    repeat: expr\n    repeat-expr: 2\ntypes:\n  s: {}\n", .Unsupported, 7, 18, "a repeated switch-on without a _ case, size or size-eos is not supported"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        _: s\n  - id: b\n    size: a.c\ntypes:\n  s:\n    seq:\n      - id: c\n        type: u1\n", .Unsupported, 11, 11, "size: a is a switch-on field; it cannot be used in expressions"},

	// instances: value instances and parse instances
	{HEAD + "instances:\n  x:\n    doc: d\n", .Unsupported, 5, 3, "instance x: an instance without pos or value is not supported"},
	{HEAD + "instances:\n  x:\n    size: 1\n", .Unsupported, 5, 3, "instance x: an instance without pos or value is not supported"},
	{HEAD + "instances:\n  x:\n    value: 1\n    pos: 0\n", .Invalid, 7, 5, `instance x: unknown key "pos"`},
	{HEAD + "instances:\n  x:\n    value: 1\n    if: 1\n", .Invalid, 7, 9, "if: expected a boolean, found an integer"},
	{HEAD + "instances:\n  x:\n    value: 1\n    if: x == 1\n", .Invalid, 6, 12, "value instance x refers to itself"},
	{HEAD + "instances:\n  x:\n    value: 1\n    if: _io.eof\n", .Unsupported, 7, 9, "_io in a value instance is not supported"},
	{HEAD + "instances:\n  x:\n    value: 1\n    enum: e\n", .Invalid, 7, 11, "x: no enum e"},
	{HEAD + "instances:\n  x:\n    value: 1 == 1\n    enum: e\nenums:\n  e:\n    1: one\n", .Invalid, 7, 5, "value instance x: enum applies only to integer values"},
	{HEAD + "instances:\n  x:\n    pos: 0\n    type: u1\n    -bits:\n      - {id: b, low: 0, high: 0}\n", .Invalid, 8, 5, "the extension -bits does not apply here"},
	{HEAD + "instances:\n  x:\n    pos: x\n    type: u1\n", .Invalid, 5, 3, "instance x refers to itself"},
	{HEAD + "instances:\n  x:\n    pos: y\n    type: u1\n  y:\n    pos: 0\n    type: s\ntypes:\n  s:\n    seq:\n      - id: a\n        size: _parent.x\n", .Invalid, 5, 3, "instance x refers to itself"},
	{HEAD + "instances:\n  x:\n    pos: 1 == 1\n    type: u1\n", .Invalid, 6, 12, "pos: expected an integer, found a boolean"},
	{HEAD + "instances:\n  x:\n    pos: 0\n", .Invalid, 6, 5, "x needs a type, size, size-eos, terminator or contents"},
	{HEAD + "instances:\n  x:\n    value: y\n  y:\n    value: x + 1\n", .Invalid, 6, 12, "value instance x refers to itself"},
	{HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  a:\n    value: 1\n", .Invalid, 8, 3, "id a is already used (line 5, column 9)"},
	{HEAD + "seq:\n  - id: b\n    size: 1\ninstances:\n  x:\n    value: b\n", .Unsupported, 9, 12, "value instance x: only integer, boolean and string values are supported"},
	{HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    instances:\n      x:\n        value: _parent.y\n", .Invalid, 11, 24, "value: t has no field y"},
	{HEAD + "instances:\n  x:\n    value: _parent.y\n", .Invalid, 6, 12, "value: _parent: t has no enclosing set here"},
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

	// sizes: what Kaitai's compiler cannot size, and what has no size
	{HEAD + "seq:\n  - id: a\n    size: sizeof<s>\ntypes:\n  s:\n    seq:\n      - id: b\n        size-eos: true\n", .Invalid, 6, 11, "size: s has no fixed size: b has none"},
	{HEAD + "seq:\n  - id: a\n    size: sizeof<s>\ntypes:\n  s:\n    seq:\n      - id: c\n        type: inner\n  inner:\n    seq:\n      - id: d\n        type: strz\n        encoding: ASCII\n", .Invalid, 6, 11, "size: s has no fixed size: c.d has none"},
	{HEAD + "seq:\n  - id: a\n    size: sizeof<r>\ntypes:\n  r:\n    seq:\n      - id: next\n        type: r\n", .Invalid, 6, 11, "size: r has no fixed size: next has none"},
	{HEAD + "seq:\n  - id: a\n    size: _sizeof\n  - id: b\n    type: u1\n", .Invalid, 6, 11, "size: t has no fixed size: a has none"},
	{HEAD + "seq:\n  - id: a\n    size: sizeof<nope>\n", .Invalid, 6, 11, "size: unknown type nope"},
	{HEAD + "seq:\n  - id: a\n    size: sizeof<str>\n", .Invalid, 6, 11, "size: str has no fixed size"},
	{HEAD + "seq:\n  - id: a\n    size: sizeof<s::x>\n", .Unsupported, 6, 11, "size: a type of another type (s::x) is not supported"},
	{HEAD + "seq:\n  - id: a\n    size: nope._sizeof\n", .Invalid, 6, 16, "size: t has no field nope"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n    repeat: expr\n    repeat-expr: 2\n  - id: a\n    size: n._sizeof\n", .Unsupported, 10, 13, "size: n is repeated; _sizeof of a repeated attribute is not supported"},
	{HEAD + "seq:\n  - id: a\n    size: v._sizeof\ninstances:\n  v:\n    value: 1\n", .Invalid, 6, 13, "size: v is a value instance, which has no _sizeof"},
	{HEAD + "seq:\n  - id: a\n    type: s(1)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n    seq:\n      - id: b\n        size: p._sizeof\n", .Invalid, 14, 17, "size: p is a param, which has no _sizeof"},
	{HEAD + "seq:\n  - id: a\n    size: 2.\n", .Unsupported, 6, 11, "size: float literals are not supported"},

	// valid
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: 256\n", .Invalid, 7, 12, "a: 256 does not fit in a UInt8"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: x + 1\n", .Invalid, 7, 12, "valid: t has no field x"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: '\"x\"'\n", .Invalid, 7, 12, "valid: expected an integer, found a string"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    size: 1\n    encoding: ASCII\n    valid: G\n", .Invalid, 9, 12, "valid: t has no field G"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    valid: 1\n", .Unsupported, 7, 12, "a: a valid constant for a blob must be a list of bytes"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    valid: '[256]'\n", .Unsupported, 7, 12, "a: a valid constant for a blob must be a list of bytes"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    valid: 1\ntypes:\n  s: {}\n", .Invalid, 7, 12, "a: valid on a user type must be an expr"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      in-enum: true\n", .Invalid, 8, 16, "a: in-enum needs an enum"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      min: 2\n      max: 1\n", .Invalid, 8, 7, "a: min is above max"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      eq: 1\n      min: 0\n", .Invalid, 8, 7, "exactly one of eq, min and max, any-of, expr and in-enum"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      expr: _ + 1\n", .Invalid, 8, 15, "valid: expected a boolean, found an integer"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      expr: _ > b\n  - id: b\n    type: u1\n", .Invalid, 8, 17, "valid: t has no field b"},
	{HEAD + "seq:\n  - id: a\n    type: f4\n    valid: 1\n", .Unsupported, 7, 12, "valid on a Float32"},

	// -bits
	{HEAD + "seq:\n  - id: a\n    size: 1\n    -bits:\n      - {id: b, low: 0, high: 0}\n", .Invalid, 8, 7, "a: -bits applies only to integer types"},
	{HEAD + "seq:\n  - id: a\n    type: b8\n    -bits:\n      - {id: b, low: 0, high: 0}\n", .Invalid, 8, 7, "a: -bits does not apply to a bit type"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: b, low: 4, high: 8}\n", .Invalid, 8, 9, "b has bits 4 to 8, not within 0 to 7"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: a, low: 0, high: 0}\n", .Invalid, 8, 14, "id a is already used"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: b, low: 0}\n", .Invalid, 8, 9, "a: a -bits entry has no high"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    -bits:\n      - {id: b, low: 0, high: 0, width: 1}\n", .Invalid, 8, 34, `-bits: unknown key "width"`},

	// params
	{HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n", .Invalid, 6, 11, "a: type s takes 1 argument, not 0"},
	{HEAD + "seq:\n  - id: a\n    type: s(1, 2)\ntypes:\n  s: {}\n", .Invalid, 6, 11, "a: type s takes 0 arguments, not 2"},
	{HEAD + "seq:\n  - id: a\n    type: s(1 == 1)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n", .Invalid, 6, 15, "type: argument 1 of s, p, must be an integer, not a boolean"},
	{HEAD + "seq:\n  - id: a\n    type: s(1 +)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n", .Syntax, 6, 16, "type: unexpected end of expression"},
	{HEAD + "seq:\n  - id: a\n    type: s(1, )\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n", .Syntax, 6, 16, "type: expected an expression after ,"},
	{HEAD + "seq:\n  - id: a\n    type: s(1\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n", .Invalid, 6, 11, "a: type s(1 does not end with )"},
	{HEAD + "seq:\n  - id: a\n    type: s(1)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n    seq:\n      - id: p\n        type: u1\n", .Invalid, 13, 13, "id p is already used"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n", .Unsupported, 7, 9, "param p has no type; params of any type are not supported"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: str\n", .Unsupported, 8, 15, "param p: type str is not supported; only integer types, bool and bytes are"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: bool\n        enum: e\n", .Invalid, 9, 9, "param p: enum applies only to integer types"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: u1\n        enum: e\n", .Invalid, 9, 15, "p: no enum e"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: u1\n        size: 1\n", .Invalid, 9, 9, `param p: unknown key "size"`},
	{HEAD + "types:\n  s:\n    params: 1\n", .Invalid, 6, 13, "params must be a sequence"},

	// recursive types: a type that contains itself, and the types in it, can
	// refer to the members of the sets enclosing it only through _root, and
	// its instances cannot refer to themselves through a field of their type
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type: s\ntypes:\n  s:\n    seq:\n      - id: b\n        type: u1\n        if: _parent.n == 0\n      - id: c\n        type: s\n        if: b == 1\n", .Unsupported, 14, 13, "if: type s contains itself, so neither it nor the types in it can refer to the members of the sets enclosing it"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type: s\ntypes:\n  s:\n    seq:\n      - id: b\n        type: u1\n      - id: u\n        type: u\n      - id: c\n        type: s\n        if: b == 1\n  u:\n    seq:\n      - id: x\n        type: u1\n        if: _parent.b == 0\n      - id: y\n        type: u1\n        if: _parent._parent.n == 0\n", .Unsupported, 26, 13, "if: type s contains itself"},
	{HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    seq:\n      - id: n\n        type: u1\n      - id: kids\n        type: s\n        repeat: expr\n        repeat-expr: n\n    instances:\n      total:\n        value: 'n + (n > 0 ? kids[0].total : 0)'\n", .Unsupported, 18, 16, "value instance total refers to itself in a field of its type"},

	// enums
	{HEAD + "enums:\n  e:\n    1:\n      doc: d\n", .Invalid, 7, 7, "enum e: a value has no id"},
	{HEAD + "enums:\n  e:\n    1:\n      id: one\n      name: x\n", .Invalid, 8, 7, `enum e: unknown key "name"`},
	{HEAD + "enums:\n  e:\n    1:\n      id: One\n", .Invalid, 7, 11, `enum value name "One" is not an identifier`},
	{HEAD + "enums:\n  e:\n    1: one\n    2:\n      id: one\n", .Invalid, 8, 11, "enum e: one appears twice"},
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
	return dump_decoded(t, &ff, input)
}

// As ksy_dump, with the schema read from path.
@(private = "file")
ksy_file_dump :: proc(t: ^testing.T, path: string, import_paths: []string, input: []byte) -> string {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.read_file_format(path, &ff, import_paths)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%s: %v at %s:%v:%v: %s", path, err.kind, err.path, err.line, err.column, err.message) do return ""
	return dump_decoded(t, &ff, input)
}

// Decodes input with ff and returns its text dump, as ksy_dump does.
@(private = "file")
dump_decoded :: proc(t: ^testing.T, ff: ^mdat.File_Format, input: []byte) -> string {
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(ff, input, &d)
	if d.err.kind != .None do return fmt.tprintf("error: %v at %v in %s", d.err.kind, d.err.offset, d.err.path)

	b := strings.builder_make(context.temp_allocator)
	werr := dmp.write_text(strings.to_writer(&b), ff, &d.tree)
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

	// meta keys that affect no decoding are ignored, and ks-version is no
	// newer than 0.11
	meta := "meta:\n  id: t\n  title: T\n  application: [A, B]\n  file-extension: t\n  xref:\n    wikidata: Q1\n  license: CC0-1.0\n  tags: [x, y]\n  ks-version: %s\nseq:\n  - id: a\n    type: u1\n"
	for v in ([]string{"0.6", "0.9", "'0.10'", "\"0.11\"", "0.11.0", "0.10.9"}) {
		expect_dump(t, v, ksy_dump(t, fmt.tprintf(meta, v), {7}), "t[0].a[0] = 7\n")
	}

	// -orig-id on a type documents its original name, as in
	// kaitai_struct_formats; nothing shows it
	expect_dump(t, "-orig-id on a type", ksy_dump(t, HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    -orig-id: S\n    seq:\n      - id: b\n        type: u1\n", {7}), "t[0].a[0].b[0] = 7\n")
}

// As ksy_dump, but the JSON dump.
@(private = "file")
ksy_json :: proc(t: ^testing.T, src: string, input: []byte) -> string {
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
	werr := dmp.write_json(strings.to_writer(&b), &ff, &d.tree)
	testing.expectf(t, werr == .None, "dump: %v", werr)
	return strings.to_string(b)
}

@(test)
ksy_imports :: proc(t: ^testing.T) {
	// relative imports are found from the importing file, absolute ones in
	// the import paths, and a schema imported twice (lib/tag) is read once.
	// Each schema has its own meta, and _root in one is its top level
	input := []byte{2, 0, 5, 1, 9, 1, 0, 0, 1, 7, 0x12, 0x34, 0x34, 0x12}
	expect_dump(t, "imports", ksy_file_dump(t, "tests/schemas/imports/main.ksy", {"tests/schemas/imports"}, input), `main[0].n[0] = 2
main[0].pairs[0].a[0] = 5
main[0].pairs[0].t[0].v[0] = 1
main[0].pairs[0].t[0].inner[0].w[0] = 9
main[0].pairs[0].t[0].inner[0].first[0] = 2
main[0].pairs[1].a[0] = 256
main[0].pairs[1].t[0].v[0] = 0
main[0].pairs[1].t[0].inner[0].first[0] = 2
main[0].tag[0].v[0] = 1
main[0].tag[0].inner[0].w[0] = 7
main[0].tag[0].inner[0].first[0] = 2
main[0].word[0].w[0] = 4660
main[0].le[0] = 4660
`)

	// an error in an imported schema names its file
	Case :: struct {
		path:         string,
		kind:         ksy.Error_Kind,
		in_file:      string,
		line, column: int,
		message:      string,
	}
	DIR :: "tests/schemas/imports/"
	cases := []Case {
		{DIR + "main.ksy", .Invalid, DIR + "main.ksy", 9, 7, "imports: /shared/word is in none of the import paths"},
		{DIR + "errors/broken_import.ksy", .Invalid, DIR + "errors/broken.ksy", 5, 11, "a: unknown type nope"},
		{DIR + "errors/bad_yaml_import.ksy", .Syntax, DIR + "errors/bad_yaml.ksy", 2, 1, "unterminated flow collection"},
		{DIR + "errors/orphan.ksy", .Invalid, DIR + "errors/orphan_lib.ksy", 7, 9, "if: _parent: o has no enclosing set here"},
		{DIR + "errors/twins.ksy", .Invalid, DIR + "errors/twins.ksy", 5, 7, "imports: two schemas have the id tag"},
	}
	for c in cases {
		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		err := ksy.read_file_format(c.path, &ff)
		defer ksy.destroy_error(&err)
		testing.expectf(
			t,
			err.kind == c.kind && err.path == c.in_file && err.line == c.line && err.column == c.column && strings.contains(err.message, c.message),
			"%s:\n  got  %v at %s:%v:%v: %s\n  want %v at %s:%v:%v: ...%s...",
			c.path, err.kind, err.path, err.line, err.column, err.message, c.kind, c.in_file, c.line, c.column, c.message)
	}
}

@(test)
ksy_parse_instances :: proc(t: ^testing.T) {
	// parse instances are read at pos in their type's stream, which does
	// not move: when an expression first refers to one (peek, from the
	// field after it; here, from inside a substream; table, through a value
	// instance), or else after their type's fields, in order. They are
	// dumped after the fields. A repeat reads on from pos, a false if reads
	// nothing, and in a substream pos and _io are the substream's
	src := HEAD + `seq:
  - id: ofs
    type: u1
  - id: kind
    type: u1
    if: peek != 0
  - id: sub
    type: sub
    size: 3
  - id: tail
    size: n - 1
instances:
  peek:
    pos: _io.pos
    type: u1
  here:
    pos: _io.pos
    type: u1
  at_ofs:
    pos: ofs
    type: u2
  table:
    pos: 5
    type: u1
    repeat: expr
    repeat-expr: 2
  never:
    pos: 0
    type: u1
    if: ofs == 0
  n:
    value: table.size
types:
  sub:
    seq:
      - id: a
        type: u1
      - id: b
        type: u1
        if: _parent.here == 0x20
    instances:
      last:
        pos: _io.size - 1
        type: u1
      parent_ofs:
        pos: _parent.ofs
        type: u1
`
	expect_dump(t, "parse instances", ksy_dump(t, src, {1, 7, 0x10, 0x11, 0x12, 0x20, 0x21}), `t[0].ofs[0] = 1
t[0].kind[0] = 7
t[0].sub[0].a[0] = 16
t[0].sub[0].b[0] = 17
t[0].sub[0].last[0] = 18
t[0].sub[0].parent_ofs[0] = 17
t[0].tail[0] = <1 bytes> 20
t[0].peek[0] = 7
t[0].here[0] = 32
t[0].at_ofs[0] = 4103
t[0].table[0] = 32
t[0].table[1] = 33
`)

	// a pos past the end of the stream, and a read at pos that runs past
	// it, fail with the instance's path
	expect_dump(t, "pos out of range", ksy_dump(t, src, {9, 7, 0x10, 0x11, 0x12, 0x20, 0x21}), "error: Offset_Out_Of_Range at 4 in t[0].sub[0].parent_ofs[0]")
	expect_dump(t, "read past the end", ksy_dump(t, src, {2, 7, 0x10, 0x11, 0x12, 0x20}), "error: Unexpected_EOF at 6 in t[0].table[1]")

	// in JSON, parse instances follow the fields, also when there are none
	both := HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  p:\n    pos: 0\n    type: u1\n  q:\n    pos: 0\n    size: 0\n    if: a == 0\n"
	expect_dump(t, "json", ksy_json(t, both, {7}), `{"t":[{"a":[7],"p":[7],"q":[]}]}` + "\n")
	only := HEAD + "instances:\n  p:\n    pos: 0\n    type: u1\n"
	expect_dump(t, "json, no fields", ksy_json(t, only, {7}), `{"t":[{"p":[7]}]}` + "\n")
}

// Strings and indexing: string literals with escapes, comparisons, + and
// .to_s and .length, a string value instance, switch-on over a string, and
// indexing an array, the elements of a repeat read so far among them, and
// bytes. An index outside the array fails.
@(test)
ksy_strings_and_indexing :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: magic
    type: str
    size: 2
    encoding: ASCII
  - id: n
    type: u1
  - id: lens
    type: u1
    repeat: expr
    repeat-expr: n
  - id: chunks
    type: 'chunk(_index == 0 ? 0 : chunks[_index - 1].total)'
    size: lens[_index]
    repeat: expr
    repeat-expr: n
  - id: tag
    size: label.length
  - id: pad
    size: chunks[n - 1].total % 3
  - id: kind
    type: strz
    encoding: ASCII
  - id: body
    type:
      switch-on: kind
      cases:
        '"one"': one
        '"t\167o"': two
    size-eos: true
instances:
  is_ab:
    value: magic == "AB"
  label:
    value: '(is_ab ? "ab" : ''other'') + "-" + n.to_s'
types:
  chunk:
    params:
      - id: before
        type: u4
    seq:
      - id: bytes
        size-eos: true
    instances:
      total:
        value: before + bytes.size + bytes[0] * 0
  one:
    seq:
      - id: v
        type: u1
  two:
    seq:
      - id: v
        type: u2
`
	expect_dump(t, "two", ksy_dump(t, src, {'A', 'B', 2, 2, 3, 1, 2, 3, 4, 5, 't', 'a', 'g', '!', 0xee, 0xff, 't', 'w', 'o', 0, 0x34, 0x12}), `t[0].magic[0] = "AB"
t[0].n[0] = 2
t[0].lens[0] = 2
t[0].lens[1] = 3
t[0].chunks[0].bytes[0] = <2 bytes> 01 02
t[0].chunks[1].bytes[0] = <3 bytes> 03 04 05
t[0].tag[0] = <4 bytes> 74 61 67 21
t[0].pad[0] = <2 bytes> ee ff
t[0].kind[0] = "two"
t[0].body[0].v[0] = 4660
`)
	expect_dump(t, "one", ksy_dump(t, src, {'X', 'Y', 1, 1, 9, 'o', 't', 'h', 'e', 'r', '-', '1', 0xee, 'o', 'n', 'e', 0, 7}), `t[0].magic[0] = "XY"
t[0].n[0] = 1
t[0].lens[0] = 1
t[0].chunks[0].bytes[0] = <1 bytes> 09
t[0].tag[0] = <7 bytes> 6f 74 68 65 72 2d 31
t[0].pad[0] = <1 bytes> ee
t[0].kind[0] = "one"
t[0].body[0].v[0] = 7
`)
	expect_dump(t, "no chunks", ksy_dump(t, src, {'A', 'B', 0, 'a', 'b', '-', '0'}), "error: Index_Out_Of_Range at 7 in t[0].pad[0]")
}

// valid with expressions: a bound that is a value instance, in-enum, expr
// with _ and with the field's own name, any-of with a string expression
// and with byte lists, a boolean against an expression, expr on the
// instances of a repeated user type with _index, and an enum constant.
// Each fails with its own error, as in Kaitai's runtimes.
@(test)
ksy_valid_expressions :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: version
    type: u1
    valid:
      min: 1
      max: limit
  - id: kind
    type: u1
    enum: kind
    valid:
      in-enum: true
  - id: flags
    type: u1
    valid:
      expr: (_ & 1) == 0 and flags < 0x80
  - id: tag
    type: str
    size: 2
    encoding: ASCII
    valid:
      any-of: ['"ab"', expected]
  - id: bom
    size: 2
    valid:
      any-of: ['[0xfe, 0xff]', '[0xff, 0xfe]']
  - id: enabled
    type: b1
    valid: version > 1
  - id: rest
    type: b7
  - id: items
    type: item
    repeat: expr
    repeat-expr: 2
    valid:
      expr: _.v >= _index
  - id: last
    type: u1
    enum: kind
    valid: kind::two
instances:
  limit:
    value: 3
  expected:
    value: '"c" + "d"'
enums:
  kind:
    1: one
    2: two
types:
  item:
    seq:
      - id: v
        type: u1
`
	ok := []byte{2, 2, 0x10, 'c', 'd', 0xff, 0xfe, 0x85, 0, 1, 2}
	expect_dump(t, "pass", ksy_dump(t, src, ok), `t[0].version[0] = 2
t[0].kind[0] = 2
t[0].flags[0] = 16
t[0].tag[0] = "cd"
t[0].bom[0] = <2 bytes> ff fe
t[0].enabled[0] = true
t[0].rest[0] = 5
t[0].items[0].v[0] = 0
t[0].items[1].v[0] = 1
t[0].last[0] = 2
`)

	Failure :: struct {
		at:    int,
		value: byte,
		want:  string,
	}
	failures := []Failure {
		{0, 4, "error: Greater_Than_Max at 0 in t[0].version[0]"},
		{1, 3, "error: Not_In_Enum at 1 in t[0].kind[0]"},
		{2, 0x11, "error: Expr_False at 2 in t[0].flags[0]"},
		{2, 0x90, "error: Expr_False at 2 in t[0].flags[0]"},
		{3, 'x', "error: Not_Any_Of at 3 in t[0].tag[0]"},
		{5, 0, "error: Not_Any_Of at 5 in t[0].bom[0]"},
		{0, 1, "error: Not_Equal at 7 in t[0].enabled[0]"},
		{9, 0, "error: Expr_False at 9 in t[0].items[1]"},
		{10, 1, "error: Not_Equal at 10 in t[0].last[0]"},
	}
	for f in failures {
		input := slice.clone(ok, context.temp_allocator)
		input[f.at] = f.value
		expect_dump(t, f.want, ksy_dump(t, src, input), f.want)
	}
}

// _parent and _root in value instances, which are evaluated for the
// instance an expression refers to them in: from their own type, from its
// parent (through an element of an array), and from the root (through two
// fields), with _parent of _parent, and _parent in a value instance used
// through _parent and in an if.
@(test)
ksy_parent_and_root_in_value_instances :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: scale
    type: u1
  - id: groups
    type: group
    repeat: expr
    repeat-expr: 2
  - id: tail
    size: groups[1].entries[0].scaled
  - id: tail2
    size: groups[0].entries[1].grand
types:
  group:
    seq:
      - id: k
        type: u1
      - id: entries
        type: entry
        repeat: expr
        repeat-expr: 2
      - id: d
        size: entries[1].scaled - entries[0].scaled
    instances:
      factor:
        value: _parent.scale * k
    types:
      entry:
        seq:
          - id: x
            type: u1
          - id: blob
            size: scaled % 3
        instances:
          scaled:
            value: x * _parent.factor + _root.scale
          grand:
            value: _parent._parent.scale
            if: _parent.k == 1
`
	input := []byte{1, 1, 1, 0xaa, 0xab, 2, 0xd0, 2, 0, 0xb0, 1, 0xe0, 0xe1, 0xf0, 0xf1}
	expect_dump(t, "outer", ksy_dump(t, src, input), `t[0].scale[0] = 1
t[0].groups[0].k[0] = 1
t[0].groups[0].entries[0].x[0] = 1
t[0].groups[0].entries[0].blob[0] = <2 bytes> aa ab
t[0].groups[0].entries[1].x[0] = 2
t[0].groups[0].entries[1].blob[0] = <0 bytes>
t[0].groups[0].d[0] = <1 bytes> d0
t[0].groups[1].k[0] = 2
t[0].groups[1].entries[0].x[0] = 0
t[0].groups[1].entries[0].blob[0] = <1 bytes> b0
t[0].groups[1].entries[1].x[0] = 1
t[0].groups[1].entries[1].blob[0] = <0 bytes>
t[0].groups[1].d[0] = <2 bytes> e0 e1
t[0].tail[0] = <1 bytes> f0
t[0].tail2[0] = <1 bytes> f1
`)
	// in the second group, whose k is 2, grand has no value
	absent, _ := strings.replace_all(src, "size: groups[0].entries[1].grand", "size: groups[1].entries[1].grand", context.temp_allocator)
	expect_dump(t, "absent", ksy_dump(t, absent, input), "error: Absent_Field at 14 in t[0].tail2[0]")
}

// Sizes and methods: sizeof<t> and bitsizeof<t> of a type with bit fields,
// which add up without alignment, as in Kaitai; _sizeof of a field, of a
// later field and of _parent's field, and of a type in the valid of its
// own field; sizes of primitive types; .to_i of a boolean, an enum and an enum
// constant; .first, .last, .min and .max of an array of integers, of bytes,
// and of an array of sets. A valid min of _sizeof fails, and .first of an
// empty array is Index_Out_Of_Range.
@(test)
ksy_sizes_and_methods :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: hdr
    type: header
  - id: flag
    type: b1
  - id: kind
    type: b7
    enum: kind
  - id: empty
    type: u1
    repeat: expr
    repeat-expr: 0
  - id: first_of_empty
    size: empty.first
    if: not flag
  - id: packed_size
    size: sizeof<packed> + bitsizeof<packed> - 24
  - id: hdr_rest
    size: hdr._sizeof - hdr.len._sizeof
  - id: prims
    size: _root.hdr.magic._sizeof + sizeof<u2> + sizeof<b9> - bitsizeof<b3>
  - id: later_size
    size: later._sizeof
  - id: to_i
    size: flag.to_i + kind.to_i + kind::two.to_i
  - id: nums
    type: u2
    repeat: expr
    repeat-expr: 3
  - id: ends
    size: nums.first + nums.last
  - id: extremes
    size: nums.min + nums.max
  - id: raw
    size: 3
  - id: raw_methods
    size: raw.first + raw.last + raw.min + raw.max
  - id: items
    type: item
    repeat: expr
    repeat-expr: 2
  - id: last_item
    size: items.last.v - items.first.v
  - id: entry
    type: entry
  - id: later
    type: u1
types:
  header:
    seq:
      - id: magic
        contents: [0x4d, 'X']
      - id: len
        type: u2
        valid:
          min: _sizeof
      - id: rest
        size: 2 * 2 - 3
      - id: maybe
        type: u1
        if: false
  packed:
    seq:
      - id: p1
        type: b4
      - id: p2
        type: u1
      - id: p3
        type: b4
      - id: p4
        type: u1
  item:
    seq:
      - id: v
        type: u1
  entry:
    seq:
      - id: body
        size: _parent.hdr._sizeof - sizeof<item> * 4
enums:
  kind:
    1: one
    2: two
`
	input := []byte{'M', 'X', 6, 0, 'r', 0x81, 'P', 'P', 'P', 'H', 'H', 'H', 'H', 'S', 'S', 'S', 'L', 'T', 'T', 'T', 'T', 1, 0, 3, 0, 2, 0, 'E', 'E', 'E', 'X', 'X', 'X', 'X', 0, 2, 1, 'R', 'R', 'R', 5, 7, 'I', 'I', 'B', 'B', 9}
	expect_dump(t, "sizes", ksy_dump(t, src, input), `t[0].hdr[0].magic[0] = <2 bytes> 4d 58
t[0].hdr[0].len[0] = 6
t[0].hdr[0].rest[0] = <1 bytes> 72
t[0].flag[0] = true
t[0].kind[0] = 1
t[0].packed_size[0] = <3 bytes> 50 50 50
t[0].hdr_rest[0] = <4 bytes> 48 48 48 48
t[0].prims[0] = <3 bytes> 53 53 53
t[0].later_size[0] = <1 bytes> 4c
t[0].to_i[0] = <4 bytes> 54 54 54 54
t[0].nums[0] = 1
t[0].nums[1] = 3
t[0].nums[2] = 2
t[0].ends[0] = <3 bytes> 45 45 45
t[0].extremes[0] = <4 bytes> 58 58 58 58
t[0].raw[0] = <3 bytes> 00 02 01
t[0].raw_methods[0] = <3 bytes> 52 52 52
t[0].items[0].v[0] = 5
t[0].items[1].v[0] = 7
t[0].last_item[0] = <2 bytes> 49 49
t[0].entry[0].body[0] = <2 bytes> 42 42
t[0].later[0] = 9
`)

	short := slice.clone(input, context.temp_allocator)
	short[2] = 5
	expect_dump(t, "valid min _sizeof", ksy_dump(t, src, short), "error: Less_Than_Min at 2 in t[0].hdr[0].len[0]")
	no_flag := slice.clone(input, context.temp_allocator)
	no_flag[5] = 0x01
	expect_dump(t, "first of empty", ksy_dump(t, src, no_flag), "error: Index_Out_Of_Range at 6 in t[0].first_of_empty[0]")
}

// size, terminator and size-eos on a switch-on field: the case chosen is
// read from the substream, whose unread bytes are skipped. With no case
// for the value, as the official compiler does, a field with a length has
// the bytes of the length as its value, with its pad-right not removed,
// also in a repeat with no _ case, and one with only a terminator is not
// read.
@(test)
ksy_switch_on_length :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: records
    type: record
    repeat: eos
types:
  record:
    seq:
      - id: kind
        type: u1
      - id: len
        type: u1
      - id: body
        type:
          switch-on: kind
          cases:
            1: one
            2: two
        size: len
      - id: name
        type:
          switch-on: kind
          cases:
            1: name
        terminator: 0
  one:
    seq:
      - id: v
        type: u1
  two:
    seq:
      - id: a
        type: u1
      - id: b
        type: u1
  name:
    seq:
      - id: text
        type: str
        size-eos: true
        encoding: ASCII
`
	expect_dump(t, "size and terminator", ksy_dump(t, src, {1, 2, 0xaa, 0xbb, 'h', 'i', 0, 2, 2, 5, 6, 3, 1, 9}), `t[0].records[0].kind[0] = 1
t[0].records[0].len[0] = 2
t[0].records[0].body[0].v[0] = 170
t[0].records[0].name[0].text[0] = "hi"
t[0].records[1].kind[0] = 2
t[0].records[1].len[0] = 2
t[0].records[1].body[0].a[0] = 5
t[0].records[1].body[0].b[0] = 6
t[0].records[2].kind[0] = 3
t[0].records[2].len[0] = 1
t[0].records[2].body[0] = <1 bytes> 09
`)
	expect_dump(t, "size past the end", ksy_dump(t, src, {3, 4, 1}), "error: Unexpected_EOF at 2 in t[0].records[0].body[0]")

	eos := HEAD + `seq:
  - id: k
    type: u1
  - id: padded
    type:
      switch-on: k
      cases:
        1: one
    size: 2
    pad-right: 0
  - id: rest
    type:
      switch-on: k
      cases:
        1: one
    size-eos: true
  - id: items
    type:
      switch-on: k
      cases:
        1: one
    size: 1
    repeat: expr
    repeat-expr: 0
types:
  one:
    seq:
      - id: v
        type: u1
`
	expect_dump(t, "size-eos, a case", ksy_json(t, eos, {1, 7, 0, 7, 8}), `{"t":[{"k":[1],"padded":[{"v":[7]}],"rest":[{"v":[7]}],"items":[]}]}` + "\n")
	expect_dump(t, "size-eos, no case", ksy_json(t, eos, {2, 7, 0, 7, 8}), `{"t":[{"k":[2],"padded":["0700"],"rest":["0708"],"items":[]}]}` + "\n")
}

// meta in a type: its endian, bit-endian and encoding apply in it and in
// the types declared in it (deeper), but not in the types it uses (other),
// as in Kaitai. Its id, title and ks-version are checked and ignored.
@(test)
ksy_type_meta :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: a
    type: u2
  - id: inner
    type: inner
  - id: other
    type: other
types:
  inner:
    meta:
      id: inner
      title: Inner
      endian: be
      bit-endian: le
      encoding: UTF-8
      ks-version: 0.9
    seq:
      - id: x
        type: u2
      - id: deeper
        type: deeper
      - id: other
        type: other
    types:
      deeper:
        seq:
          - id: v
            type: u2
          - id: bits
            type: b3
          - id: s
            type: str
            size: 2
  other:
    seq:
      - id: w
        type: u2
`
	expect_dump(t, "type meta", ksy_dump(t, src, {1, 2, 1, 2, 1, 2, 0x05, 'h', 'i', 1, 2, 3, 0}), `t[0].a[0] = 513
t[0].inner[0].x[0] = 258
t[0].inner[0].deeper[0].v[0] = 258
t[0].inner[0].deeper[0].bits[0] = 5
t[0].inner[0].deeper[0].s[0] = "hi"
t[0].inner[0].other[0].w[0] = 513
t[0].other[0].w[0] = 3
`)
}

// switch-on cases of primitive, bit and string types, read as fields of
// those types, as the official compiler reads them: a string has the
// field's size and pad-right (sized, tags 5 and 6), and the other types
// ignore them (tag 1), so that the field's size is read only for a string,
// a user type or no case. No byte is skipped after a bit type chosen, so the
// next bit type reads the bits it left over (items, tags 4 and 6), and the
// field after the switch-on does not start at a byte. A case value's
// offset is where the stream is when it is read.
@(test)
ksy_switch_on_cases :: proc(t: ^testing.T) {
	src := HEAD + `  encoding: ASCII
seq:
  - id: tag
    type: u1
  - id: plain
    type:
      switch-on: tag
      cases:
        1: u1
        2: s2be
        3: f4
        4: b12
        5: strz
        6: b1
        7: one
  - id: sized
    size: 4
    pad-right: 0x20
    type:
      switch-on: tag
      cases:
        1: u2
        5: strz
        6: str
        7: one
  - id: items
    type:
      switch-on: tag
      cases:
        1: u1
        _: b4
    repeat: expr
    repeat-expr: 2
  - id: last
    type: u1
types:
  one:
    seq:
      - id: v
        type: u1
`
	Case :: struct {
		input: []byte,
		want:  string,
	}
	for c in ([]Case {
		{{1, 7, 0x34, 0x12, 0x0a, 0x0b, 0x0c}, "t[0].tag[0] = 1\nt[0].plain[0] = 7\nt[0].sized[0] = 4660\nt[0].items[0] = 10\nt[0].items[1] = 11\nt[0].last[0] = 12\n"},
		{{2, 0xff, 0xfe, 'a', 'b', 0x20, 0x20, 0xab, 0x0c}, "t[0].tag[0] = 2\nt[0].plain[0] = -2\nt[0].sized[0] = <4 bytes> 61 62 20 20\nt[0].items[0] = 10\nt[0].items[1] = 11\nt[0].last[0] = 12\n"},
		{{3, 0, 0, 0xc0, 0x3f, 1, 2, 3, 4, 0x12, 0x0c}, "t[0].tag[0] = 3\nt[0].plain[0] = 1.5\nt[0].sized[0] = <4 bytes> 01 02 03 04\nt[0].items[0] = 1\nt[0].items[1] = 2\nt[0].last[0] = 12\n"},
		{{4, 0xab, 0xcd, 1, 2, 3, 4, 0xef, 0x99}, "t[0].tag[0] = 4\nt[0].plain[0] = 2748\nt[0].sized[0] = <4 bytes> 01 02 03 04\nt[0].items[0] = 13\nt[0].items[1] = 14\nt[0].last[0] = 153\n"},
		{{5, 'h', 'i', 0, 'o', 'k', 0x20, 0x20, 0x12, 0x0c}, "t[0].tag[0] = 5\nt[0].plain[0] = \"hi\"\nt[0].sized[0] = \"ok\"\nt[0].items[0] = 1\nt[0].items[1] = 2\nt[0].last[0] = 12\n"},
		{{6, 0x80, 'a', 'b', 0x20, 0x20, 0xa5, 0x0c}, "t[0].tag[0] = 6\nt[0].plain[0] = true\nt[0].sized[0] = \"ab\"\nt[0].items[0] = 0\nt[0].items[1] = 1\nt[0].last[0] = 12\n"},
		{{7, 0x42, 0x43, 0x44, 0x45, 0x46, 0x12, 0x0c}, "t[0].tag[0] = 7\nt[0].plain[0].v[0] = 66\nt[0].sized[0].v[0] = 67\nt[0].items[0] = 1\nt[0].items[1] = 2\nt[0].last[0] = 12\n"},
		{{9, 0xde, 0xad, 0xbe, 0xef, 0x12, 0x0c}, "t[0].tag[0] = 9\nt[0].sized[0] = <4 bytes> de ad be ef\nt[0].items[0] = 1\nt[0].items[1] = 2\nt[0].last[0] = 12\n"},
	}) {
		expect_dump(t, fmt.tprintf("tag %v", c.input[0]), ksy_dump(t, src, c.input), c.want)
	}
	expect_dump(t, "json", ksy_json(t, src, {5, 'h', 'i', 0, 'o', 'k', 0x20, 0x20, 0x12, 0x0c}), `{"t":[{"tag":[5],"plain":["hi"],"sized":["ok"],"items":[1,2],"last":[12]}]}` + "\n")
	expect_dump(t, "past the end", ksy_dump(t, src, {2, 0xff}), "error: Unexpected_EOF at 1 in t[0].plain[0]")

	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {4, 0xab, 0xcd, 1, 2, 3, 4, 0xef, 0x99}, &d, spans = true)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v in %s", d.err.kind, d.err.offset, d.err.path) do return
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, dmp.write_text(strings.to_writer(&b), &ff, &d.tree, offsets = true) == .None, "write_text failed")
	expect_dump(t, "offsets", strings.to_string(b), `t[0].tag[0] = 4 @0x0
t[0].plain[0] = 2748 @0x1
t[0].sized[0] = <4 bytes> 01 02 03 04 @0x3
t[0].items[0] = 13 @0x7
t[0].items[1] = 14 @0x7
t[0].last[0] = 153 @0x8
`)
}

// Recursive types: a type inside itself, in a repeat with a param (kids),
// through a switch-on case and as the schema's own top-level type, by its
// meta id (item, t), and through a parse instance (next). The fields of a
// type inside it are read as its own, and its value instances evaluated
// for each instance (kids[0].total), and its nested types still refer to
// it through _parent (label). The _io of an enclosing instance is that of
// the instance each is in. Schemas that import each other can contain
// each other, but an imported schema whose type contains itself cannot use
// its _root, which is its outermost instance.
@(test)
ksy_recursive_types :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: base
    type: u1
  - id: tree
    type: node(0)
  - id: list
    type: item
  - id: expr
    type: rec_expr
instances:
  at:
    pos: _io.size - 2
    type: jump
types:
  node:
    params:
      - id: depth
        type: u1
    seq:
      - id: n
        type: u1
      - id: kids
        type: node(depth + 1)
        repeat: expr
        repeat-expr: n
      - id: label
        type: label
      - id: kid_total
        size: 'n > 0 ? kids[0].total : 0'
    instances:
      total:
        value: n + depth + _root.base
    types:
      label:
        seq:
          - id: len
            type: u1
          - id: text
            size: len
            if: _parent.depth < 2
  item:
    seq:
      - id: kind
        type: u1
      - id: body
        type:
          switch-on: kind
          cases:
            1: item
            2: t
            _: leaf
  leaf:
    seq:
      - id: v
        type: u2
  rec_expr:
    seq:
      - id: op
        type: u1
      - id: args
        type: rec_expr
        repeat: expr
        repeat-expr: op
  jump:
    seq:
      - id: to
        type: u1
    instances:
      next:
        pos: to
        type: jump
        if: to != 0
`
	expect_dump(t, "tree, list and jumps", ksy_dump(t, src, {1, 2, 1, 0, 1, 2, 97, 98, 88, 89, 90, 0, 0, 1, 99, 80, 81, 82, 1, 2, 0, 0, 0, 0, 65, 66, 0, 2, 0, 1, 0, 32, 0}), `t[0].base[0] = 1
t[0].tree[0].n[0] = 2
t[0].tree[0].kids[0].n[0] = 1
t[0].tree[0].kids[0].kids[0].n[0] = 0
t[0].tree[0].kids[0].kids[0].label[0].len[0] = 1
t[0].tree[0].kids[0].kids[0].kid_total[0] = <0 bytes>
t[0].tree[0].kids[0].label[0].len[0] = 2
t[0].tree[0].kids[0].label[0].text[0] = <2 bytes> 61 62
t[0].tree[0].kids[0].kid_total[0] = <3 bytes> 58 59 5a
t[0].tree[0].kids[1].n[0] = 0
t[0].tree[0].kids[1].label[0].len[0] = 0
t[0].tree[0].kids[1].label[0].text[0] = <0 bytes>
t[0].tree[0].kids[1].kid_total[0] = <0 bytes>
t[0].tree[0].label[0].len[0] = 1
t[0].tree[0].label[0].text[0] = <1 bytes> 63
t[0].tree[0].kid_total[0] = <3 bytes> 50 51 52
t[0].list[0].kind[0] = 1
t[0].list[0].body[0].kind[0] = 2
t[0].list[0].body[0].body[0].base[0] = 0
t[0].list[0].body[0].body[0].tree[0].n[0] = 0
t[0].list[0].body[0].body[0].tree[0].label[0].len[0] = 0
t[0].list[0].body[0].body[0].tree[0].label[0].text[0] = <0 bytes>
t[0].list[0].body[0].body[0].tree[0].kid_total[0] = <0 bytes>
t[0].list[0].body[0].body[0].list[0].kind[0] = 0
t[0].list[0].body[0].body[0].list[0].body[0].v[0] = 16961
t[0].list[0].body[0].body[0].expr[0].op[0] = 0
t[0].list[0].body[0].body[0].at[0].to[0] = 32
t[0].list[0].body[0].body[0].at[0].next[0].to[0] = 0
t[0].expr[0].op[0] = 2
t[0].expr[0].args[0].op[0] = 0
t[0].expr[0].args[1].op[0] = 1
t[0].expr[0].args[1].args[0].op[0] = 0
t[0].at[0].to[0] = 32
t[0].at[0].next[0].to[0] = 0
`)
	expect_dump(t, "deeper list", ksy_dump(t, src, {3, 0, 0, 1, 1, 1, 7, 9, 0, 3, 0, 0, 0, 14, 0}), `t[0].base[0] = 3
t[0].tree[0].n[0] = 0
t[0].tree[0].label[0].len[0] = 0
t[0].tree[0].label[0].text[0] = <0 bytes>
t[0].tree[0].kid_total[0] = <0 bytes>
t[0].list[0].kind[0] = 1
t[0].list[0].body[0].kind[0] = 1
t[0].list[0].body[0].body[0].kind[0] = 1
t[0].list[0].body[0].body[0].body[0].kind[0] = 7
t[0].list[0].body[0].body[0].body[0].body[0].v[0] = 9
t[0].expr[0].op[0] = 3
t[0].expr[0].args[0].op[0] = 0
t[0].expr[0].args[1].op[0] = 0
t[0].expr[0].args[2].op[0] = 0
t[0].at[0].to[0] = 14
t[0].at[0].next[0].to[0] = 0
`)

	io := HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type: s\n    size: 4\ntypes:\n  s:\n    seq:\n      - id: b\n        type: u1\n      - id: c\n        type: s\n        size: 3\n        if: b == 1\n    instances:\n      up:\n        io: _parent._io\n        pos: 0\n        type: u1\n"
	expect_dump(t, "_parent._io", ksy_dump(t, io, {9, 1, 5, 0, 0}), "t[0].n[0] = 9\nt[0].a[0].b[0] = 1\nt[0].a[0].c[0].b[0] = 5\nt[0].a[0].c[0].up[0] = 1\nt[0].a[0].up[0] = 9\n")

	DIR :: "tests/schemas/recursive/"
	expect_dump(t, "imports that contain each other", ksy_file_dump(t, DIR + "cycle_a.ksy", nil, {1, 2, 3, 0}), `cycle_a[0].n[0] = 1
cycle_a[0].b[0].m[0] = 2
cycle_a[0].b[0].a[0].n[0] = 3
cycle_a[0].b[0].a[0].b[0].m[0] = 0
`)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.read_file_format(DIR + "imported_root.ksy", &ff)
	defer ksy.destroy_error(&err)
	testing.expectf(t, err.kind == .Unsupported && err.path == DIR + "chain.ksy" && err.line == 8 && err.column == 9 && strings.contains(err.message, "type chain contains itself"), "imported _root: %v at %s:%v:%v: %s", err.kind, err.path, err.line, err.column, err.message)
}

// Set instances nest at most reader.MAX_DEPTH deep, and through parse
// instances read from expressions, which take more stack, until the
// decoder has used reader.MAX_STACK, at a depth that depends on the build.
// Deeper ones are Too_Deep.
@(test)
ksy_too_deep :: proc(t: ^testing.T) {
	nest := "meta:\n  id: nest\nseq:\n  - id: flag\n    type: u1\n  - id: next\n    type: nest\n    if: flag != 0\n  - id: tail\n    type: u1\n"
	// flags, then a tail byte for each instance
	levels :: proc(n: int) -> []byte {
		input := make([]byte, 2 * n, context.temp_allocator)
		for i in 0 ..< n - 1 do input[i] = 1
		for i in n ..< 2 * n do input[i] = 7
		return input
	}
	dump := ksy_dump(t, nest, levels(rdr.MAX_DEPTH))
	testing.expectf(t, strings.count(dump, "\n") == 2 * rdr.MAX_DEPTH && strings.has_suffix(dump, "\nnest[0].tail[0] = 7\n"), "MAX_DEPTH levels: %d lines, ending %q", strings.count(dump, "\n"), dump[max(0, len(dump) - 40):])

	got := ksy_dump(t, nest, levels(rdr.MAX_DEPTH + 1))
	want := fmt.tprintf("error: Too_Deep at %v in nest[0]", rdr.MAX_DEPTH)
	testing.expectf(t, strings.has_prefix(got, want) && strings.count(got, ".next[0]") == rdr.MAX_DEPTH, "MAX_DEPTH + 1 levels: %.80s", got)

	through_instances := "meta:\n  id: p\nseq:\n  - id: flag\n    type: u1\n  - id: x\n    size: 0\n    if: flag != 0 and child.flag < 2\ninstances:\n  child:\n    pos: _io.pos\n    type: p\n    if: flag != 0\n"
	ones := make([]byte, rdr.MAX_DEPTH, context.temp_allocator)
	slice.fill(ones, 1)
	testing.expect(t, strings.has_prefix(ksy_dump(t, through_instances, ones), "error: Too_Deep at "), "parse instances read from expressions")
}

// io on parse instances: each is read at its pos in the stream io gives,
// which is that of an instance being decoded (_parent._io, and _io in a
// ?:), or the kept stream of a set instance read before (names._io). _io
// in its own expressions is still its instance's stream, and a pos out of
// range fails at the instance's position. A stream of a field that was not
// read is absent.
@(test)
ksy_parse_instance_io :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: names
    type: names
    size: 6
  - id: entries
    type: entry
    size: 3
    repeat: expr
    repeat-expr: 2
types:
  names:
    seq:
      - id: all
        size-eos: true
  entry:
    seq:
      - id: ofs
        type: u1
      - id: len
        type: u1
      - id: flags
        type: u1
    instances:
      name:
        io: _root.names._io
        pos: ofs
        size: len
      last:
        io: _parent._io
        pos: _io.size - 1
        type: u1
      first:
        io: '(flags & 1) != 0 ? _io : _root._io'
        pos: 0
        type: u1
`
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {'a', 'b', 'c', 'd', 'e', 'f', 1, 2, 1, 4, 2, 0}, &d, spans = true)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v in %s", d.err.kind, d.err.offset, d.err.path) do return
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, dmp.write_text(strings.to_writer(&b), &ff, &d.tree, offsets = true) == .None, "write_text failed")
	expect_dump(t, "offsets", strings.to_string(b), `t[0].names[0].all[0] = <6 bytes> 61 62 63 64 65 66 @0x0
t[0].entries[0].ofs[0] = 1 @0x6
t[0].entries[0].len[0] = 2 @0x7
t[0].entries[0].flags[0] = 1 @0x8
t[0].entries[0].name[0] = <2 bytes> 62 63 @0x1
t[0].entries[0].last[0] = 99 @0x2
t[0].entries[0].first[0] = 1 @0x6
t[0].entries[1].ofs[0] = 4 @0x9
t[0].entries[1].len[0] = 2 @0xA
t[0].entries[1].flags[0] = 0 @0xB
t[0].entries[1].name[0] = <2 bytes> 65 66 @0x4
t[0].entries[1].last[0] = 99 @0x2
t[0].entries[1].first[0] = 97 @0x0
`)

	expect_dump(t, "pos out of range", ksy_dump(t, src, {'a', 'b', 'c', 'd', 'e', 'f', 7, 0, 0, 4, 2, 0}), "error: Offset_Out_Of_Range at 9 in t[0].entries[0].name[0]")

	// the stream of a field that was not read, and of one that was
	later := HEAD + `seq:
  - id: a
    type: u1
  - id: s
    type: s
    size: 1
    if: a == 0
instances:
  x:
    io: s._io
    pos: 0
    type: u1
types:
  s:
    seq:
      - id: v
        type: u1
`
	expect_dump(t, "not read", ksy_dump(t, later, {1, 9}), "error: Absent_Field at 1 in t[0].x[0]")
	expect_dump(t, "read", ksy_dump(t, later, {0, 9}), "t[0].a[0] = 0\nt[0].s[0].v[0] = 9\nt[0].x[0] = 9\n")
}

// if and enum on value instances: one has a value only when its if is
// true, which is evaluated in its own instance, also when it is referred
// to from outside; with none, a reference to it fails as one to an absent
// field. An enum keeps the integer, and compares with the enum's constants.
@(test)
ksy_value_instance_if_enum :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: hdr
    type: hdr
  - id: body
    size: hdr.len_body
  - id: big
    type: u1
    if: hdr.kind == kinds::big
types:
  hdr:
    seq:
      - id: flags
        type: u1
      - id: extra
        type: u1
        if: has_extra
    instances:
      has_extra:
        value: (flags & 1) != 0
      len_body:
        value: extra
        if: has_extra
      kind:
        value: flags >> 4
        enum: kinds
enums:
  kinds:
    0: small
    1: big
`
	expect_dump(t, "if true", ksy_dump(t, src, {0x11, 2, 0xaa, 0xbb, 5}), `t[0].hdr[0].flags[0] = 17
t[0].hdr[0].extra[0] = 2
t[0].body[0] = <2 bytes> aa bb
t[0].big[0] = 5
`)
	expect_dump(t, "if false", ksy_dump(t, src, {0x00, 0xaa}), "error: Absent_Field at 1 in t[0].body[0]")
}

@(test)
ksy_kaitai_features :: proc(t: ^testing.T) {
	// if, value instances (Bool and Int, one referring to a later one, used
	// in the type and from outside it), a substream read with repeat: eos,
	// repeat: until over _ and _io.eof, enum (with a value in the long
	// form), and switch-on whose cases are enum constants and an integer,
	// with no case for stop
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
    9:
      id: stop
      doc: the last block
      -orig-id: STOP
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

	// size-eos: the rest of the stream, for a byte array, a str and a
	// substream; inside a substream, the rest of the substream
	eos := HEAD + `seq:
  - id: len
    type: u1
  - id: sub
    type: sub
    size: len
  - id: rest
    type: sub
    size-eos: true
types:
  sub:
    seq:
      - id: a
        type: u1
      - id: tail
        size-eos: true
`
	expect_dump(t, "size-eos", ksy_dump(t, eos, {2, 1, 2, 3, 4, 5}), `t[0].len[0] = 2
t[0].sub[0].a[0] = 1
t[0].sub[0].tail[0] = <1 bytes> 02
t[0].rest[0].a[0] = 3
t[0].rest[0].tail[0] = <2 bytes> 04 05
`)
	expect_dump(t, "size-eos empty", ksy_dump(t, eos, {1, 1}), "error: Unexpected_EOF at 2 in t[0].rest[0].a[0]")
	str_eos := HEAD + "seq:\n  - id: s\n    type: str\n    encoding: ASCII\n    size-eos: true\n"
	expect_dump(t, "str size-eos", ksy_dump(t, str_eos, {'h', 'i'}), "t[0].s[0] = \"hi\"\n")
	expect_dump(t, "str size-eos empty", ksy_dump(t, str_eos, {}), "t[0].s[0] = \"\"\n")

	// terminator: strz; a byte array up to its terminator, which is
	// consumed, kept with include, or left with consume: false; a
	// substream; a str to the end with eos-error: false. With a size,
	// pad-right is removed from the end before the bytes are cut at the
	// terminator
	term := HEAD + `seq:
  - id: z
    type: strz
    encoding: ASCII
  - id: line
    terminator: 0x0a
    include: true
  - id: word
    type: str
    encoding: ASCII
    terminator: 0x20
    consume: false
  - id: space
    type: u1
  - id: sub
    type: sub
    terminator: 0x3b
  - id: padded
    type: str
    encoding: ASCII
    size: 4
    pad-right: 0x20
  - id: cut
    size: 4
    terminator: 0
    pad-right: 0xff
  - id: tail
    type: str
    encoding: ASCII
    terminator: 0
    eos-error: false
types:
  sub:
    seq:
      - id: a
        type: u1
      - id: rest
        size-eos: true
`
	term_input := []byte{'a', 'b', 0, 'x', '\n', 'h', 'i', ' ', 1, 2, 3, ';', 'o', 'k', ' ', ' ', 5, 0xff, 0, 0xff, 'e', 'n', 'd'}
	expect_dump(t, "terminator", ksy_dump(t, term, term_input), `t[0].z[0] = "ab"
t[0].line[0] = <2 bytes> 78 0a
t[0].word[0] = "hi"
t[0].space[0] = 32
t[0].sub[0].a[0] = 1
t[0].sub[0].rest[0] = <2 bytes> 02 03
t[0].padded[0] = "ok"
t[0].cut[0] = <2 bytes> 05 ff
t[0].tail[0] = "end"
`)
	expect_dump(t, "no terminator", ksy_dump(t, term, {'a', 'b'}), "error: Unexpected_EOF at 0 in t[0].z[0]")

	// include without consume leaves the reader at the terminator, as the
	// C++ and Python runtimes do (the JavaScript one moves one byte
	// further whenever include is set)
	kept := HEAD + "seq:\n  - id: a\n    terminator: 0\n    include: true\n    consume: false\n  - id: b\n    type: u1\n"
	expect_dump(t, "include without consume", ksy_dump(t, kept, {7, 0}), "t[0].a[0] = <2 bytes> 07 00\nt[0].b[0] = 0\n")

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

@(test)
ksy_bit_types :: proc(t: ^testing.T) {
	// bit types read on from the bits left over, most significant first
	// unless le; b1 is a boolean, unless it has an enum. As in Kaitai, a
	// field after a bit type, and not one, starts at a byte, before its if
	// (n), but a field after a user type does not (after), so the next bit
	// type reads the bits sub left (stale). repeat: eos reads the bits left
	// at the end, and a parse instance starts at a byte
	src := HEAD + `seq:
  - id: ver
    type: b3
  - id: flag
    type: b1
  - id: kind
    type: b1
    enum: kind
  - id: low
    type: b3le
  - id: n
    type: u1
    if: ver == 5
  - id: opt
    type: u1
    if: flag
  - id: wide
    type: b12
  - id: sub
    type: sub
  - id: after
    type: u1
  - id: stale
    type: b4
  - id: nibbles
    type: b4
    repeat: eos
types:
  sub:
    seq:
      - id: x
        type: b4
instances:
  again:
    pos: 0
    type: b3
enums:
  kind:
    0: a
    1: b
`
	expect_dump(t, "bits", ksy_dump(t, src, {0xb3, 0x07, 0x2a, 0xab, 0xcd, 0xe1, 0x99, 0x5f}), `t[0].ver[0] = 5
t[0].flag[0] = true
t[0].kind[0] = 0
t[0].low[0] = 3
t[0].n[0] = 7
t[0].opt[0] = 42
t[0].wide[0] = 2748
t[0].sub[0].x[0] = 14
t[0].after[0] = 153
t[0].stale[0] = 1
t[0].nibbles[0] = 5
t[0].nibbles[1] = 15
t[0].again[0] = 5
`)
	expect_dump(t, "bits, flag false", ksy_dump(t, src, {0xa3, 0x07, 0xab, 0xcd, 0xe1, 0x99}), `t[0].ver[0] = 5
t[0].flag[0] = false
t[0].kind[0] = 0
t[0].low[0] = 3
t[0].n[0] = 7
t[0].wide[0] = 2748
t[0].sub[0].x[0] = 14
t[0].after[0] = 153
t[0].stale[0] = 1
t[0].again[0] = 5
`)
	expect_dump(t, "bits past the end", ksy_dump(t, src, {0xb3, 0x07, 0x2a, 0xab}), "error: Unexpected_EOF at 3 in t[0].wide[0]")

	// each element of repeat: eos must consume input, which an instance of
	// bit types does without starting a byte
	pairs := HEAD + "seq:\n  - id: p\n    type: pair\n    repeat: eos\ntypes:\n  pair:\n    seq:\n      - id: a\n        type: b2\n      - id: b\n        type: b2\n"
	expect_dump(t, "pairs", ksy_dump(t, pairs, {0xe4}), "t[0].p[0].a[0] = 3\nt[0].p[0].b[0] = 2\nt[0].p[1].a[0] = 1\nt[0].p[1].b[0] = 0\n")

	// meta bit-endian, a be suffix, booleans in JSON, and a 64-bit read
	// whose low 6 bits are the 6 left over from the first byte
	le := "meta:\n  id: t\n  bit-endian: le\nseq:\n  - id: a\n    type: b1\n  - id: b\n    type: b1be\n  - id: c\n    type: b64\n"
	expect_dump(t, "bit-endian le", ksy_json(t, le, {0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f}), `{"t":[{"a":[true],"b":[false],"c":[18446744073709551552]}]}` + "\n")
}

@(test)
ksy_params :: proc(t: ^testing.T) {
	// the arguments of a type are evaluated where each instance is read,
	// with _index, and as in Kaitai, after the bytes of its substream
	// (_io.pos is the parent's, past them), or after pos; each switch-on
	// case has its own. Expressions in the type, and its value
	// instances, refer to its params, which are not dumped
	src := HEAD + `seq:
  - id: n
    type: u1
  - id: raw
    size: 2
  - id: recs
    type: rec(n + _index, _index == 1, raw)
    repeat: expr
    repeat-expr: 2
  - id: pick
    type:
      switch-on: n
      cases:
        1: rec(0, true, raw)
        _: rec(1, false, raw)
  - id: sub
    type: at(_io.pos)
    size: 2
instances:
  first:
    pos: 1
    type: rec(_io.pos, false, raw)
types:
  rec:
    params:
      - id: len
        type: u1
      - id: flag
        type: bool
      - id: tag
        type: bytes
    seq:
      - id: data
        size: twice / 2
      - id: extra
        type: u1
        if: flag and tag.size == 2
    instances:
      twice:
        value: len * 2
  at:
    params:
      - id: start
        type: u4
    seq:
      - id: v
        type: u1
      - id: w
        type: u1
        if: start == 10
`
	expect_dump(t, "params, n = 1", ksy_dump(t, src, {1, 0xaa, 0xbb, 1, 2, 3, 4, 5, 6, 7}), `t[0].n[0] = 1
t[0].raw[0] = <2 bytes> aa bb
t[0].recs[0].data[0] = <1 bytes> 01
t[0].recs[1].data[0] = <2 bytes> 02 03
t[0].recs[1].extra[0] = 4
t[0].pick[0].data[0] = <0 bytes>
t[0].pick[0].extra[0] = 5
t[0].sub[0].v[0] = 6
t[0].sub[0].w[0] = 7
t[0].first[0].data[0] = <1 bytes> aa
`)
	// a block scalar, with its line breaks
	block := HEAD + "seq:\n  - id: a\n    type: |\n      s(\n        2\n      )\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n    seq:\n      - id: v\n        size: p\n"
	expect_dump(t, "params in a block scalar", ksy_dump(t, block, {1, 2}), "t[0].a[0].v[0] = <2 bytes> 01 02\n")

	expect_dump(t, "params, n = 2", ksy_dump(t, src, {2, 0xaa, 0xbb, 1, 2, 3, 4, 5, 6, 7, 8, 9}), `t[0].n[0] = 2
t[0].raw[0] = <2 bytes> aa bb
t[0].recs[0].data[0] = <2 bytes> 01 02
t[0].recs[1].data[0] = <3 bytes> 03 04 05
t[0].recs[1].extra[0] = 6
t[0].pick[0].data[0] = <1 bytes> 07
t[0].sub[0].v[0] = 8
t[0].first[0].data[0] = <1 bytes> aa
`)

	// the top-level type of an imported schema can have params
	expect_dump(t, "imported params", ksy_file_dump(t, "tests/schemas/params/main.ksy", nil, {2, 5, 6, 7}), `main[0].n[0] = 2
main[0].items[0].values[0] = 5
main[0].items[0].values[1] = 6
main[0].items[0].extra[0] = 7
`)
}

@(test)
ksy_spans :: proc(t: ^testing.T) {
	// as Kaitai's debug mode records them: from the position before each
	// value to the one after, so a bit type that takes only bits left over
	// is empty (b), a strz holds its terminator, a bit field has its
	// integer's, a set instance its substream, and a parse instance starts
	// at its pos. bytes grows as it is read, keeping its spans
	src := HEAD + `seq:
  - id: a
    type: b4
  - id: b
    type: b4
  - id: name
    type: strz
    encoding: ASCII
  - id: flags
    type: u1
    -bits:
      - {id: lo, low: 0, high: 3}
  - id: sub
    type: sub
    size: 3
  - id: bytes
    type: u1
    repeat: eos
instances:
  peek:
    pos: 1
    type: u1
types:
  sub:
    seq:
      - id: x
        type: u2
`
	input := []byte{0x12, 'h', 'i', 0, 0x35, 0xaa, 0xbb, 0xcc, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}

	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, input, &d, spans = true)
	if !testing.expectf(t, d.err.kind == .None, "%v at %v in %s", d.err.kind, d.err.offset, d.err.path) do return

	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, dmp.write_text(strings.to_writer(&b), &ff, &d.tree, offsets = true) == .None, "write_text failed")
	expect_dump(t, "offsets", strings.to_string(b), `t[0].a[0] = 1 @0x0
t[0].b[0] = 2 @0x1
t[0].name[0] = "hi" @0x1
t[0].flags[0] = 53 @0x4
t[0].lo[0] = 5 @0x4
t[0].sub[0].x[0] = 48042 @0x5
t[0].bytes[0] = 1 @0x8
t[0].bytes[1] = 2 @0x9
t[0].bytes[2] = 3 @0xA
t[0].bytes[3] = 4 @0xB
t[0].bytes[4] = 5 @0xC
t[0].bytes[5] = 6 @0xD
t[0].bytes[6] = 7 @0xE
t[0].bytes[7] = 8 @0xF
t[0].bytes[8] = 9 @0x10
t[0].bytes[9] = 10 @0x11
t[0].peek[0] = 104 @0x1
`)

	r := root_instance(&ff, &d)
	Want :: struct {
		name:  string,
		index: int,
		span:  fld.Span,
	}
	for w in ([?]Want{{"a", 0, {0, 1}}, {"b", 0, {1, 0}}, {"name", 0, {1, 3}}, {"lo", 0, {4, 1}}, {"sub", 0, {5, 3}}, {"bytes", 9, {17, 1}}, {"peek", 0, {1, 1}}}) {
		got := fld.value_span(r.instance, field_slot(r, w.name), w.index)
		testing.expectf(t, got == w.span, "%s[%v]: span %v, want %v", w.name, w.index, got, w.span)
	}
	testing.expect_value(t, fld.root_span(&d.tree, 0), fld.Span{0, len(input)})
	sub := field_instance(r, "sub")
	testing.expect_value(t, fld.value_span(sub.instance, field_slot(sub, "x"), 0), fld.Span{5, 2})
}
