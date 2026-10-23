package tests

import dmp "../zelbyn/dump"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdat "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

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
	{HEAD + "seq:\n  - id: a\n    type: s\n  - id: b\n    type: u\n  - id: c\n    size: '(1 == 1 ? a : b).x'\ntypes:\n  s:\n    seq:\n      - id: x\n        type: u1\n  u:\n    seq:\n      - id: x\n        type: u1\n", .Unsupported, 10, 20, "size: ?: on sets of different types is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: s\n  - id: b\n    type: s\n  - id: c\n    size: '(1 == 1 ? a : b).up'\ntypes:\n  s:\n    seq:\n      - id: x\n        type: u1\n    instances:\n      up:\n        value: _parent.a.x\n", .Unsupported, 10, 29, "size: value instance up refers to the sets that enclose its instance, which it cannot through ?:"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n  - id: b\n    size: 1\n    if: a.to_s('EBCDIC') == ''\n", .Unsupported, 9, 9, `if: encoding "EBCDIC" is not supported`},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    process: xor(1)\n", .Unsupported, 7, 14, "a: process xor(1) is not supported; only zlib is"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    process: zlib\n", .Invalid, 7, 5, "a: process applies only to a byte array or a user type"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    process: zlib\ntypes:\n  s: {}\n", .Invalid, 7, 5, "a: process needs size, size-eos or terminator"},
	{HEAD + "seq:\n  - id: a\n    size: 2\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n    process: zlib\n", .Unsupported, 11, 5, "a: process on a switch-on with a case that is not a user type is not supported"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    io: _root._io\n", .Unsupported, 7, 5, "attribute a: io is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    sizee: 1\n", .Invalid, 7, 5, `attribute a: unknown key "sizee"`},
	{HEAD + "params:\n  - id: p\n    type: s\ntypes:\n  s:\n    params:\n      - id: q\n        type: u1\n", .Unsupported, 5, 9, "param p: its type s has params, which nothing can give"},
	{HEAD + "params:\n  - id: p\n    type: nope\n", .Invalid, 5, 9, "param p: unknown type nope"},
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

	// to-string: parsed, and otherwise ignored
	{HEAD + "to-string: '(1 +'\n", .Syntax, 4, 17, "to-string: unexpected end of expression"},
	{HEAD + "to-string: [a]\n", .Invalid, 4, 12, "to-string must be a scalar"},

	// the top level and meta
	{"# nothing\n", .Invalid, 0, 0, "the schema is empty"},
	{"seq: []\n", .Invalid, 1, 1, "the schema has no meta"},
	{"meta:\n  title: t\n", .Invalid, 2, 3, "meta has no id"},
	{"meta:\n  id: T\n", .Invalid, 2, 7, `meta id "T" is not an identifier`},
	{"meta:\n  id: t\n  endian: little\n", .Invalid, 3, 11, `endian must be le or be, not "little"`},
	{"meta:\n  id: t\n  endian:\n    switch-on: x\n", .Invalid, 4, 5, "endian: switch-on needs cases"},
	{"meta:\n  id: t\n  endian:\n    switch-on: x\n    cases:\n      1: le\n", .Unsupported, 4, 5, "endian: switch-on is not supported on the top-level type of the schema compiled"},
	{"meta:\n  id: t\n  encoding: Shift_JIS\n", .Unsupported, 3, 13, `encoding "Shift_JIS" is not supported; only ASCII, UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ISO-8859-1, windows-1251, windows-1252 and IBM437 are`},
	{"meta:\n  id: t\n  encoding: UTF-16\n", .Unsupported, 3, 13, `encoding "UTF-16" is not supported`},
	{"meta:\n  id: t\n  ks-version: 0.12\n", .Unsupported, 3, 15, "ks-version 0.12 is newer than 0.11, the Kaitai version zelbyn follows"},
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
	{HEAD + "types:\n  u:\n    meta:\n      endian:\n        switch-on: x\n", .Invalid, 8, 9, "endian: switch-on needs cases"},
	{HEAD + "types:\n  u:\n    meta:\n      endian:\n        switch-on: x\n        cases:\n          1: middle\n", .Invalid, 10, 14, `endian must be le or be, not "middle"`},
	{HEAD + "types:\n  u:\n    meta:\n      endian:\n        switch-on: x\n        cases:\n          1: le\n        size: 1\n", .Invalid, 11, 9, `endian: unknown key "size"`},
	{HEAD + "seq:\n  - id: a\n    type: u\ntypes:\n  u:\n    meta:\n      endian:\n        switch-on: _root.a\n        cases:\n          1: le\n    seq:\n      - id: b\n        type: u\n        if: false\n", .Unsupported, 11, 9, "type u, whose endian is a switch-on, contains itself, which is not supported"},
	{HEAD + "seq:\n  - id: a\n    type: u\ntypes:\n  u:\n    meta:\n      endian:\n        switch-on: 1.5\n        cases:\n          1: le\n", .Unsupported, 11, 20, "endian: switch-on over a float is not supported"},
	{"meta:\n  id: t\n  bit-endian:\n    switch-on: x\n", .Unsupported, 4, 5, "bit-endian: switch-on is not supported"},
	{HEAD + "types:\n  u:\n    meta:\n      encoding: Shift_JIS\n", .Unsupported, 7, 17, `encoding "Shift_JIS" is not supported`},
	{HEAD + "types:\n  u:\n    meta:\n      ks-version: 0.12\n", .Unsupported, 7, 19, "ks-version 0.12 is newer than 0.11"},
	{"meta:\n  id: t\nseq:\n  - id: a\n    type: u\ntypes:\n  u:\n    meta:\n      encoding: ASCII\n    seq:\n      - id: b\n        type: w\n  w:\n    seq:\n      - id: s\n        type: strz\n", .Invalid, 16, 15, "s: str needs an encoding, or meta encoding"},

	// attributes
	{HEAD + "seq:\n  - type: u1\n  - id: a\n    size: _unnamed0\n", .Invalid, 7, 11, "size: t has no field _unnamed0"},
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
	{HEAD + "seq:\n  - id: a\n    type: u1\n    enum: s::e\n", .Invalid, 7, 11, "a: no enum s::e"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    enum: s::e\ntypes:\n  s:\n    enums:\n      f:\n        1: x\n", .Invalid, 7, 11, "a: no enum s::e"},
	{HEAD + "seq:\n  - id: a\n    size: 's::e::y'\ntypes:\n  s:\n    enums:\n      e:\n        1: x\n", .Invalid, 6, 12, "enum s::e has no value y"},

	// switch-on
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n", .Invalid, 7, 7, "a: switch-on needs cases"},
	{HEAD + "seq:\n  - id: a\n    type:\n      cases: {}\n", .Invalid, 7, 7, "a: a type mapping needs switch-on"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases: {}\n      default: x\n", .Invalid, 9, 7, `a: type: unknown key "default"`},
	{HEAD + "seq:\n  - id: b\n    size: 1\n  - id: a\n    type:\n      switch-on: b\n      cases: {}\n", .Unsupported, 9, 18, "a: switch-on over a byte array is not supported; only over an integer, a boolean or a string"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1 == 1\n      cases:\n        1 == 1: u1\n", .Unsupported, 9, 9, "a: a case must be true or false"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: str\n", .Invalid, 9, 12, "a: str needs size, size-eos or terminator"},
	{"meta:\n  id: t\nseq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: u2\n", .Invalid, 8, 12, "a: u2 needs le or be, or meta endian"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    type:\n      switch-on: 1\n      cases:\n        1: strz\n", .Invalid, 10, 12, "a: a case of type strz needs meta encoding"},
	{HEAD + "  encoding: ASCII\nseq:\n  - id: a\n    size: 1\n    encoding: ASCII\n    type:\n      switch-on: 1\n      cases:\n        1: strz\n", .Invalid, 8, 5, "a: encoding applies only to str"},
	{HEAD + "seq:\n  - id: a\n    consume: false\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n", .Invalid, 6, 5, "a: consume applies only with terminator or strz"},
	{HEAD + "  encoding: ASCII\nseq:\n  - id: a\n    size: 2\n    consume: false\n    type:\n      switch-on: 1\n      cases:\n        1: strz\n", .Invalid, 8, 5, "a: consume does not apply with a size"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: nope\n", .Invalid, 9, 12, "a: unknown type nope"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        n: s\ntypes:\n  s: {}\n", .Unsupported, 11, 9, "a case must be an integer or an enum constant"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: s\n        0x1: s\ntypes:\n  s: {}\n", .Invalid, 10, 9, "a: case 1 is already given (line 9, column 9)"},
	{HEAD + "seq:\n  - id: a\n    type: s1\n    enum: e\n  - id: b\n    type:\n      switch-on: a\n      cases:\n        e::m: u1\n        -1: u1\nenums:\n  e:\n    -1: m\n", .Invalid, 13, 9, "b: case -1 is already given (line 12, column 9)"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        9223372036854775808: u1\n", .Unsupported, 9, 9, "a: case 9223372036854775808 is not supported; only cases from -2^63 to 2^63 - 1"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        -9223372036854775809: u1\n", .Unsupported, 9, 9, "a: case -9223372036854775809 is not supported; only cases from -2^63 to 2^63 - 1"},
	{HEAD + "  encoding: ASCII\nseq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n        2: strz\n  - id: b\n    size: a\n", .Unsupported, 13, 11, "size: a is a switch-on field whose values can be an integer or a string"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n    size: 2\n  - id: b\n    size: a\n", .Unsupported, 12, 11, "size: a is a switch-on field whose values can be a byte array or an integer"},
	{HEAD + "seq:\n  - id: a\n    type:\n      switch-on: 1\n      cases:\n        _: s\n  - id: b\n    size: a.c\ntypes:\n  s:\n    seq:\n      - id: c\n        type: u1\n", .Unsupported, 11, 11, "size: a is a switch-on field whose cases are user types; it cannot be used in expressions"},

	// instances: value instances and parse instances
	{HEAD + "instances:\n  x:\n    doc: d\n", .Unsupported, 5, 3, "instance x: an instance without pos or value that reads bytes is not supported"},
	{HEAD + "instances:\n  x:\n    size: 1\n", .Unsupported, 5, 3, "instance x: an instance without pos or value that reads bytes is not supported"},
	{HEAD + "instances:\n  x:\n    value: 1\n    pos: 0\n", .Invalid, 7, 5, `instance x: unknown key "pos"`},
	{HEAD + "instances:\n  x:\n    value: 1\n    if: 1\n", .Invalid, 7, 9, "if: expected a boolean, found an integer"},
	{HEAD + "instances:\n  x:\n    value: 1\n    if: x == 1\n", .Invalid, 6, 12, "value instance x refers to itself"},
	{HEAD + "instances:\n  x:\n    value: 1\n    enum: e\n", .Invalid, 7, 11, "x: no enum e"},
	{HEAD + "instances:\n  x:\n    value: 1 == 1\n    enum: e\nenums:\n  e:\n    1: one\n", .Invalid, 7, 5, "value instance x: enum applies only to integer values"},
	{HEAD + "instances:\n  x:\n    pos: 0\n    type: u1\n    -bits:\n      - {id: b, low: 0, high: 0}\n", .Invalid, 8, 5, "the extension -bits does not apply here"},
	{HEAD + "instances:\n  x:\n    pos: x\n    type: u1\n", .Invalid, 5, 3, "instance x refers to itself"},
	{HEAD + "instances:\n  x:\n    pos: y\n    type: u1\n  y:\n    pos: 0\n    type: s\ntypes:\n  s:\n    seq:\n      - id: a\n        size: _parent.x\n", .Invalid, 5, 3, "instance x refers to itself"},
	{HEAD + "instances:\n  x:\n    pos: 1 == 1\n    type: u1\n", .Invalid, 6, 12, "pos: expected an integer, found a boolean"},
	{HEAD + "instances:\n  x:\n    pos: 0\n", .Invalid, 6, 5, "x needs a type, size, size-eos, terminator or contents"},
	{HEAD + "instances:\n  x:\n    value: y\n  y:\n    value: x + 1\n", .Invalid, 6, 12, "value instance x refers to itself"},
	{HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  a:\n    value: 1\n", .Invalid, 8, 3, "id a is already used (line 5, column 9)"},
	{HEAD + "seq:\n  - id: k\n    type: u1\n  - id: a\n    type:\n      switch-on: k\n      cases:\n        1: s\ninstances:\n  x:\n    value: a.as<t>\ntypes:\n  s: {}\n  t: {}\n", .Invalid, 14, 14, "a has no case of type t"},
	{HEAD + "seq:\n  - id: a\n    type: s\ninstances:\n  x:\n    value: a.as<s>\ntypes:\n  s: {}\n", .Unsupported, 9, 14, "a cast to a user type (s) is only supported of a switch-on field read once"},
	{HEAD + "seq:\n  - id: b\n    size: 1\ninstances:\n  x:\n    value: b.as<u4>\n", .Invalid, 9, 12, "expected an integer, found a byte array"},
	{HEAD + "seq:\n  - id: a\n    type: s\ntypes:\n  s:\n    instances:\n      x:\n        value: _parent.y\n", .Invalid, 11, 24, "value: t has no field y"},
	{HEAD + "instances:\n  x:\n    value: _parent.y\n", .Invalid, 6, 12, "value: _parent: t has no enclosing set here"},
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
	{HEAD + "seq:\n  - id: a\n    size: sizeof<s::x>\n", .Invalid, 6, 11, "size: unknown type s::x"},
	{HEAD + "seq:\n  - id: a\n    type: s::x\ntypes:\n  s: {}\n", .Invalid, 6, 11, "a: unknown type s::x"},
	{HEAD + "seq:\n  - id: a\n    size: nope._sizeof\n", .Invalid, 6, 16, "size: t has no field nope"},
	{HEAD + "seq:\n  - id: n\n    type: u1\n    repeat: expr\n    repeat-expr: 2\n  - id: a\n    size: n._sizeof\n", .Unsupported, 10, 13, "size: n is repeated; _sizeof of a repeated attribute is not supported"},
	{HEAD + "seq:\n  - id: a\n    size: v._sizeof\ninstances:\n  v:\n    value: 1\n", .Invalid, 6, 13, "size: v is a value instance, which has no _sizeof"},
	{HEAD + "seq:\n  - id: a\n    type: s(1)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u1\n    seq:\n      - id: b\n        size: p._sizeof\n", .Invalid, 14, 17, "size: p is a param, which has no _sizeof"},
	{HEAD + "seq:\n  - id: a\n    size: 2.\n", .Invalid, 6, 11, "size: expected an integer, found a float"},

	// valid
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: 256\n", .Invalid, 7, 12, "a: 256 does not fit in a UInt8"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: x + 1\n", .Invalid, 7, 12, "valid: t has no field x"},
	{HEAD + "seq:\n  - id: a\n    type: u1\n    valid: '\"x\"'\n", .Invalid, 7, 12, "valid: expected an integer, found a string"},
	{HEAD + "seq:\n  - id: a\n    type: str\n    size: 1\n    encoding: ASCII\n    valid: G\n", .Invalid, 9, 12, "valid: t has no field G"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    valid: 1\n", .Invalid, 7, 12, "valid: expected a byte array, found an integer"},
	{HEAD + "seq:\n  - id: a\n    size: 1\n    valid: '[256]'\n", .Invalid, 7, 13, "valid: expected a byte array, found an array"},
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
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: struct\n", .Unsupported, 8, 15, "param p: type struct is not supported; only integer types, bool, bytes, str and user types are"},
	{HEAD + "seq:\n  - id: a\n    type: s(_root)\ntypes:\n  s:\n    params:\n      - id: p\n        type: nope\n", .Invalid, 6, 11, "a: param p of type s has an unknown type nope"},
	{HEAD + "seq:\n  - id: a\n    type: u\n  - id: b\n    type: s(_root)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u\n  u:\n    seq:\n      - id: x\n        type: u1\n", .Invalid, 8, 13, "type: argument 1 of s, p, must be a u, not a t"},
	{HEAD + "seq:\n  - id: a\n    type: s(1)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u\n  u:\n    seq:\n      - id: x\n        type: u1\n", .Invalid, 6, 13, "type: argument 1 of s, p, must be a set, not an integer"},
	{HEAD + "seq:\n  - id: b\n    type: s(_root)\ntypes:\n  s:\n    params:\n      - id: p\n        type: t\n", .Unsupported, 6, 13, "type: argument 1 of s, p, is an instance of a set that encloses this field, which is not supported"},
	{HEAD + "seq:\n  - id: h\n    type: u\n  - id: b\n    type: s(h)\ntypes:\n  s:\n    params:\n      - id: p\n        type: u\n    seq:\n      - id: x\n        size: p.up\n  u:\n    seq:\n      - id: n\n        type: u1\n    instances:\n      up:\n        value: _parent.h.n\n", .Unsupported, 16, 17, "size: value instance up refers to the sets that enclose its instance, which it cannot through a param"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: bool\n        enum: e\n", .Invalid, 9, 9, "param p: enum applies only to integer types"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: u1\n        enum: e\n", .Invalid, 9, 15, "p: no enum e"},
	{HEAD + "types:\n  s:\n    params:\n      - id: p\n        type: u1\n        size: 1\n", .Invalid, 9, 9, `param p: unknown key "size"`},
	{HEAD + "types:\n  s:\n    params: 1\n", .Invalid, 6, 13, "params must be a sequence"},

	// recursive types: a type that contains itself, and the types in it, can
	// refer to the members of the sets enclosing it only through _root, and
	// its instances cannot refer to themselves through a field of their type
	{HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type: s\ntypes:\n  s:\n    seq:\n      - id: b\n        type: u1\n        if: _parent.n == 0\n      - id: c\n        type: s\n        if: b == 1\n", .Unsupported, 14, 13, "if: type s contains itself, so neither it nor the types in it can refer to the members of the sets enclosing it"},
	// parent
	{HEAD + "seq:\n  - id: a\n    type: u1\n    parent: _parent\n", .Invalid, 7, 5, "a: parent applies only to a user type"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    parent: _root\ntypes:\n  s: {}\n", .Unsupported, 7, 13, "a: parent is only supported as _parent, _parent._parent and so on"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    parent: _parent\ntypes:\n  s: {}\n", .Invalid, 7, 13, "parent: _parent: t has no enclosing set here"},
	{HEAD + "seq:\n  - id: a\n    type: s\n    parent: 1\ntypes:\n  s: {}\n", .Invalid, 7, 13, "parent: expected"},
	{HEAD + "instances:\n  i:\n    type:\n      switch-on: 1\n      cases:\n        1: u1\n", .Unsupported, 5, 3, "instance i: an instance without pos or value that reads bytes is not supported"},
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
dump_decoded :: proc(t: ^testing.T, ff: ^mdat.File_Format, input: []byte, args: []fld.Value = nil) -> string {
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(ff, input, &d, args = args)
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

	// - keys zelbyn does not know are ignored, as the official tools do
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
	// a list of original names, as in elf.ksy, leaves the id
	expect_dump(t, "-orig-id list", ksy_dump(t, HEAD + "seq:\n  - id: a\n    -orig-id: [A32, A64]\n    type: u1\n", {7}), "t[0].a[0] = 7\n")

	// an attribute without an id is named _unnamed and its index in seq, as
	// in Kaitai, also among bit fields
	expect_dump(t, "unnamed", ksy_dump(t, HEAD + "seq:\n  - id: a\n    type: u1\n  - size: 2\n  - type: b4\n  - id: b\n    type: b4\n", {7, 1, 2, 0x35}), "t[0].a[0] = 7\nt[0]._unnamed1[0] = <2 bytes> 01 02\nt[0]._unnamed2[0] = 3\nt[0].b[0] = 5\n")

	// _io in a value instance is the stream of its set instance, as it is
	// when the value is first used, which is kept from then on: start and
	// end are saved as the items are read, for raw, which is read once the
	// root is
	positions := HEAD + `seq:
  - id: items
    type: item
    repeat: expr
    repeat-expr: 2
  - id: tail
    size: len_file - 5
    if: not at_end
instances:
  len_file:
    value: _io.size
  at_end:
    value: _io.eof
types:
  item:
    seq:
      - id: mark
        size: 0
        if: start >= 0
      - id: n
        type: u1
      - id: data
        size: n
      - id: mark2
        size: 0
        if: end >= 0
    instances:
      start:
        value: _io.pos
      end:
        value: _io.pos
      raw:
        pos: start
        size: end - start
`
	expect_dump(t, "_io.pos saved", ksy_dump(t, positions, {1, 0xaa, 2, 0xbb, 0xcc, 0xdd}), `t[0].items[0].mark[0] = <0 bytes>
t[0].items[0].n[0] = 1
t[0].items[0].data[0] = <1 bytes> aa
t[0].items[0].mark2[0] = <0 bytes>
t[0].items[0].raw[0] = <2 bytes> 01 aa
t[0].items[1].mark[0] = <0 bytes>
t[0].items[1].n[0] = 2
t[0].items[1].data[0] = <2 bytes> bb cc
t[0].items[1].mark2[0] = <0 bytes>
t[0].items[1].raw[0] = <3 bytes> 02 bb cc
t[0].tail[0] = <1 bytes> dd
`)

	// once a's instance is read, its stream is as it was then: its size, at
	// 1 of 2 bytes
	kept := HEAD + `seq:
  - id: a
    type: sub
    size: 2
  - id: b
    size: a.left
  - id: c
    size: a.pos_now
  - id: d
    type: u1
    if: not a.done
types:
  sub:
    seq:
      - id: x
        type: u1
    instances:
      left:
        value: _io.size
      pos_now:
        value: _io.pos
      done:
        value: _io.eof
`
	expect_dump(t, "_io kept", ksy_dump(t, kept, {9, 8, 1, 2, 3, 4}), `t[0].a[0].x[0] = 9
t[0].b[0] = <2 bytes> 01 02
t[0].c[0] = <1 bytes> 03
t[0].d[0] = 4
`)

	// ?: on two sets of one type gives either instance, whose fields and
	// value instances an expression reaches; ?: on a float and an integer
	// gives a float
	choice := HEAD + `seq:
  - id: flag
    type: u1
  - id: here
    type: mask
    if: flag == 1
  - id: hdr
    type: hdr
  - id: a
    size: chosen.len
  - id: b
    size: chosen.doubled
  - id: c
    size: '(flag == 1 ? here : hdr.inner).len + 1'
  - id: d
    size: half.to_i
instances:
  chosen:
    value: 'flag == 1 ? here : hdr.inner'
  half:
    value: 'flag == 1 ? 2.5 : flag'
types:
  hdr:
    seq:
      - id: inner
        type: mask
  mask:
    seq:
      - id: len
        type: u1
    instances:
      doubled:
        value: len * 2 + zero
      zero:
        value: 0
`
	expect_dump(t, "?: on sets, here", ksy_dump(t, choice, {0x01, 0x02, 0x07, 0x41, 0x41, 0x42, 0x42, 0x42, 0x42, 0x43, 0x43, 0x43, 0x44, 0x44}), `t[0].flag[0] = 1
t[0].here[0].len[0] = 2
t[0].hdr[0].inner[0].len[0] = 7
t[0].a[0] = <2 bytes> 41 41
t[0].b[0] = <4 bytes> 42 42 42 42
t[0].c[0] = <3 bytes> 43 43 43
t[0].d[0] = <2 bytes> 44 44
`)
	expect_dump(t, "?: on sets, hdr", ksy_dump(t, choice, {0x00, 0x03, 0x41, 0x41, 0x41, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x43, 0x43, 0x43, 0x43}), `t[0].flag[0] = 0
t[0].hdr[0].inner[0].len[0] = 3
t[0].a[0] = <3 bytes> 41 41 41
t[0].b[0] = <6 bytes> 42 42 42 42 42 42
t[0].c[0] = <4 bytes> 43 43 43 43
t[0].d[0] = <0 bytes>
`)

	// integers are exact up to 2^64 - 1: vlq_base128_le.ksy's arithmetic
	// on u8 params and values, with 0x8000_0000_0000_0000, gives the
	// value and its signed reading of a varint as Kaitai's Python runtime
	// does (2^64 - 1, 5, 2^63, 2^63 - 1 and 100)
	vlq := HEAD + `seq:
  - id: num
    type: vlq
  - id: neg
    size: 1
    if: num.value_signed < 0
  - id: big
    size: 1
    if: num.value == 18446744073709551615
types:
  vlq:
    seq:
      - id: groups
        type: |
          group(
            _index,
            _index != 0 ? groups[_index - 1].interm_value : 0,
            _index != 0 ? (_index == 9 ? 0x8000_0000_0000_0000 : groups[_index - 1].multiplier * 128) : 1
          )
        repeat: until
        repeat-until: not _.has_next
    types:
      group:
        params:
          - id: idx
            type: s4
          - id: prev_interm_value
            type: u8
          - id: multiplier
            type: u8
        seq:
          - id: has_next
            type: b1
            valid: 'idx == 9 ? false : has_next'
          - id: value
            type: b7
            valid:
              max: '(idx == 9 ? 1 : 0b111_1111).as<u8>'
        instances:
          interm_value:
            value: (prev_interm_value + value * multiplier).as<u8>
    instances:
      len:
        value: groups.size
      value:
        value: groups.last.interm_value
      sign_bit:
        value: '(len == 10 ? 0x8000_0000_0000_0000 : groups.last.multiplier * 0b100_0000).as<u8>'
      value_signed:
        value: 'sign_bit > 0 and value >= sign_bit ? -(sign_bit - (value - sign_bit)).as<s8> : value.as<s8>'
`
	expect_dump(t, "vlq, max", ksy_dump(t, vlq, {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0xaa, 0xbb}), `t[0].num[0].groups[0].has_next[0] = true
t[0].num[0].groups[0].value[0] = 127
t[0].num[0].groups[1].has_next[0] = true
t[0].num[0].groups[1].value[0] = 127
t[0].num[0].groups[2].has_next[0] = true
t[0].num[0].groups[2].value[0] = 127
t[0].num[0].groups[3].has_next[0] = true
t[0].num[0].groups[3].value[0] = 127
t[0].num[0].groups[4].has_next[0] = true
t[0].num[0].groups[4].value[0] = 127
t[0].num[0].groups[5].has_next[0] = true
t[0].num[0].groups[5].value[0] = 127
t[0].num[0].groups[6].has_next[0] = true
t[0].num[0].groups[6].value[0] = 127
t[0].num[0].groups[7].has_next[0] = true
t[0].num[0].groups[7].value[0] = 127
t[0].num[0].groups[8].has_next[0] = true
t[0].num[0].groups[8].value[0] = 127
t[0].num[0].groups[9].has_next[0] = false
t[0].num[0].groups[9].value[0] = 1
t[0].neg[0] = <1 bytes> aa
t[0].big[0] = <1 bytes> bb
`)
	expect_dump(t, "vlq, 5", ksy_dump(t, vlq, {0x05, 0xaa, 0xbb}), `t[0].num[0].groups[0].has_next[0] = false
t[0].num[0].groups[0].value[0] = 5
`)
	expect_dump(t, "vlq, 2^63", ksy_dump(t, vlq, {0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0xaa, 0xbb}), `t[0].num[0].groups[0].has_next[0] = true
t[0].num[0].groups[0].value[0] = 0
t[0].num[0].groups[1].has_next[0] = true
t[0].num[0].groups[1].value[0] = 0
t[0].num[0].groups[2].has_next[0] = true
t[0].num[0].groups[2].value[0] = 0
t[0].num[0].groups[3].has_next[0] = true
t[0].num[0].groups[3].value[0] = 0
t[0].num[0].groups[4].has_next[0] = true
t[0].num[0].groups[4].value[0] = 0
t[0].num[0].groups[5].has_next[0] = true
t[0].num[0].groups[5].value[0] = 0
t[0].num[0].groups[6].has_next[0] = true
t[0].num[0].groups[6].value[0] = 0
t[0].num[0].groups[7].has_next[0] = true
t[0].num[0].groups[7].value[0] = 0
t[0].num[0].groups[8].has_next[0] = true
t[0].num[0].groups[8].value[0] = 0
t[0].num[0].groups[9].has_next[0] = false
t[0].num[0].groups[9].value[0] = 1
t[0].neg[0] = <1 bytes> aa
`)
	expect_dump(t, "vlq, 2^63 - 1", ksy_dump(t, vlq, {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xaa, 0xbb}), `t[0].num[0].groups[0].has_next[0] = true
t[0].num[0].groups[0].value[0] = 127
t[0].num[0].groups[1].has_next[0] = true
t[0].num[0].groups[1].value[0] = 127
t[0].num[0].groups[2].has_next[0] = true
t[0].num[0].groups[2].value[0] = 127
t[0].num[0].groups[3].has_next[0] = true
t[0].num[0].groups[3].value[0] = 127
t[0].num[0].groups[4].has_next[0] = true
t[0].num[0].groups[4].value[0] = 127
t[0].num[0].groups[5].has_next[0] = true
t[0].num[0].groups[5].value[0] = 127
t[0].num[0].groups[6].has_next[0] = true
t[0].num[0].groups[6].value[0] = 127
t[0].num[0].groups[7].has_next[0] = true
t[0].num[0].groups[7].value[0] = 127
t[0].num[0].groups[8].has_next[0] = false
t[0].num[0].groups[8].value[0] = 127
t[0].neg[0] = <1 bytes> aa
`)
	expect_dump(t, "vlq, 100", ksy_dump(t, vlq, {0x64, 0xaa, 0xbb}), `t[0].num[0].groups[0].has_next[0] = false
t[0].num[0].groups[0].value[0] = 100
t[0].neg[0] = <1 bytes> aa
`)
	expect_dump(t, "vlq, 65 bits", ksy_dump(t, vlq, {0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02, 0xaa}), "error: Greater_Than_Max at 10 in t[0].num[0].groups[9].value[0]")

	// .size, .pos and .eof of the stream of another set instance: of the
	// root, of a field's substream, of a ?: of those, and from a value
	// instance, of _parent once it is read (up_size)
	streams := HEAD + `seq:
  - id: n
    type: u1
  - id: hdr
    type: hdr
    size: n
  - id: body
    type: body
  - id: a
    size: hdr._io.size - 1
  - id: b
    size: '(n > 2 ? hdr._io : _root._io).size - (n > 2 ? 2 : 12)'
  - id: c
    size: 1
    if: hdr._io.eof
  - id: d
    size: body.left
  - id: f
    size: body.inner.up_size - _root._io.size
instances:
  tail:
    pos: _io.size - 1
    size: 1
types:
  hdr:
    seq:
      - id: x
        type: u1
  body:
    seq:
      - id: y
        type: u1
      - id: inner
        type: inner
    instances:
      left:
        value: _root._io.size - _root._io.pos
    types:
      inner:
        seq:
          - id: z
            type: u1
        instances:
          up_size:
            value: _parent._io.size
`
	expect_dump(t, "streams, 1", ksy_dump(t, streams, {0x03, 0x09, 0x08, 0x07, 0x05, 0x06, 0xa1, 0xa2, 0xb1, 0xc1, 0xd1, 0xd2, 0xd3, 0xd4}), `t[0].n[0] = 3
t[0].hdr[0].x[0] = 9
t[0].body[0].y[0] = 5
t[0].body[0].inner[0].z[0] = 6
t[0].a[0] = <2 bytes> a1 a2
t[0].b[0] = <1 bytes> b1
t[0].d[0] = <5 bytes> c1 d1 d2 d3 d4
t[0].f[0] = <0 bytes>
t[0].tail[0] = <1 bytes> d4
`)
	expect_dump(t, "streams, 2", ksy_dump(t, streams, {0x01, 0x09, 0x05, 0x06, 0xb1, 0xb2, 0xc1, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7}), `t[0].n[0] = 1
t[0].hdr[0].x[0] = 9
t[0].body[0].y[0] = 5
t[0].body[0].inner[0].z[0] = 6
t[0].a[0] = <0 bytes>
t[0].b[0] = <2 bytes> b1 b2
t[0].c[0] = <1 bytes> c1
t[0].d[0] = <7 bytes> d1 d2 d3 d4 d5 d6 d7
t[0].f[0] = <0 bytes>
t[0].tail[0] = <1 bytes> d7
`)

	// methods: .to_s(encoding) of bytes, in a switch-on (RIFF, LIST) and
	// in UTF-16LE (wide), .substring of a string, and .as<bytes> of an
	// array of integers
	methods := HEAD + `seq:
  - id: tag
    size: 4
  - id: name
    size: 4
    type: str
    encoding: UTF-8
  - id: body
    type:
      switch-on: tag.to_s('ASCII')
      cases:
        '"RIFF"': riff_body
        '"LIST"': list_body
  - id: w
    size: 4
  - id: wide
    size: 2
    if: w.to_s('UTF-16LE') == "AB"
  - id: sub_ok
    size: 1
    if: name.substring(1, 3) == "bc"
  - id: ids
    type: u1
    repeat: expr
    repeat-expr: 3
  - id: mfg
    size: 1
    if: '[ids[0] + 0x40, ids[1] + 0x40, ids[2] + 0x40].as<bytes>.to_s("ASCII") == "ABC"'
types:
  riff_body:
    seq:
      - id: x
        type: u1
  list_body:
    seq:
      - id: y
        type: u2
`
	expect_dump(t, "methods, 1", ksy_dump(t, methods, {0x52, 0x49, 0x46, 0x46, 0x61, 0x62, 0x63, 0x64, 0x07, 0x41, 0x00, 0x42, 0x00, 0x01, 0x02, 0x03, 0x01, 0x02, 0x03, 0x09}), `t[0].tag[0] = <4 bytes> 52 49 46 46
t[0].name[0] = "abcd"
t[0].body[0].x[0] = 7
t[0].w[0] = <4 bytes> 41 00 42 00
t[0].wide[0] = <2 bytes> 01 02
t[0].sub_ok[0] = <1 bytes> 03
t[0].ids[0] = 1
t[0].ids[1] = 2
t[0].ids[2] = 3
t[0].mfg[0] = <1 bytes> 09
`)
	expect_dump(t, "methods, 2", ksy_dump(t, methods, {0x4c, 0x49, 0x53, 0x54, 0x78, 0x79, 0x7a, 0x77, 0x07, 0x08, 0x41, 0x41, 0x41, 0x41, 0x01, 0x01, 0x01, 0x09}), `t[0].tag[0] = <4 bytes> 4c 49 53 54
t[0].name[0] = "xyzw"
t[0].body[0].y[0] = 2055
t[0].w[0] = <4 bytes> 41 41 41 41
t[0].ids[0] = 1
t[0].ids[1] = 1
t[0].ids[2] = 1
`)

	// process: zlib decompresses the bytes of a byte array, once pad-right
	// is removed (a) or at a terminator (b), and the substream of a user
	// type, whose offsets count from its field's start (e); also the bytes
	// of a switch-on that chooses no case (f)
	zlib_src := HEAD + `seq:
  - id: len_a
    type: u1
  - id: a
    size: len_a + 2
    pad-right: 0
    process: zlib
  - id: b
    terminator: 0
    process: zlib
  - id: len_e
    type: u1
  - id: e
    type:
      switch-on: a.size
      cases:
        11: inner
    size: len_e
    process: zlib
  - id: lens
    type: u1
    repeat: expr
    repeat-expr: 2
  - id: d
    size: lens[_index]
    process: zlib
    repeat: expr
    repeat-expr: 2
  - id: len_f
    type: u1
  - id: f
    type:
      switch-on: a.size
      cases:
        99: inner
    size: len_f
    process: zlib
types:
  inner:
    seq:
      - id: x
        type: u1
      - id: rest
        size-eos: true
`
	zlib_input := []byte{0x13, 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x1a, 0x0b, 0x04, 0x5d, 0x00, 0x00, 0x78, 0x01, 0x4b, 0x4c, 0x4a, 0x4e, 0x49, 0x4d, 0x4b, 0xcf, 0x48, 0x44, 0xa3, 0x01, 0x75, 0x60, 0x09, 0x6d, 0x00, 0x0b, 0x78, 0x9c, 0x63, 0xe7, 0xe0, 0x04, 0x00, 0x00, 0x31, 0x00, 0x19, 0x0a, 0x08, 0x78, 0x9c, 0xab, 0xa8, 0x04, 0x00, 0x01, 0x6b, 0x00, 0xf2, 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01, 0x10, 0x78, 0x9c, 0x2b, 0xcd, 0x4b, 0xce, 0xc8, 0x2f, 0x4e, 0xcd, 0x03, 0x00, 0x0f, 0x59, 0x03, 0x64}
	expect_dump(t, "process: zlib", ksy_dump(t, zlib_src, zlib_input), `t[0].len_a[0] = 19
t[0].a[0] = <11 bytes> 68 65 6c 6c 6f 20 77 6f 72 6c 64
t[0].b[0] = <24 bytes> 61 62 63 64 65 66 67 68 61 62 63 64 65 66 67 68 ...
t[0].len_e[0] = 11
t[0].e[0].x[0] = 7
t[0].e[0].rest[0] = <2 bytes> 08 09
t[0].lens[0] = 10
t[0].lens[1] = 8
t[0].d[0] = <2 bytes> 78 79
t[0].d[1] = <0 bytes>
t[0].len_f[0] = 16
t[0].f[0] = <8 bytes> 75 6e 63 68 6f 73 65 6e
`)
	zlib_input[1] = 0
	expect_dump(t, "process: zlib, not zlib", ksy_dump(t, zlib_src, zlib_input), "error: Decompression_Failed at 1 in t[0].a[0]")

	// in repeat-until, _index counts the elements read, as in Kaitai's
	// JavaScript, C++ and Java runtimes
	until := HEAD + "seq:\n  - id: items\n    type: u1\n    repeat: until\n    repeat-until: _index >= 2\n  - id: rest\n    size-eos: true\n"
	expect_dump(t, "_index in repeat-until", ksy_dump(t, until, {1, 2, 3}), "t[0].items[0] = 1\nt[0].items[1] = 2\nt[0].rest[0] = <1 bytes> 03\n")

	// float fields in expressions, with integers; .to_i rounds toward zero
	floats := HEAD + `seq:
  - id: x
    type: f4
  - id: y
    type: f8
  - id: d
    size: (x * 2 + y).to_i
  - id: e
    type: u1
    repeat: until
    repeat-until: _ > ratio
  - id: g
    type: f4
    repeat: expr
    repeat-expr: 2
  - id: h
    size: g[1].to_i - g.first.to_i
instances:
  ratio:
    value: x / 2
`
	float_input := []byte{0, 0, 0xc0, 0x3f, 0, 0, 0, 0, 0, 0, 2, 0x40, 'a', 'b', 'c', 'd', 'e', 0, 1, 0, 0, 0xc0, 0xbf, 0, 0, 0x30, 0x40, 'x', 'y', 'z'}
	expect_dump(t, "floats", ksy_dump(t, floats, float_input), `t[0].x[0] = 1.5
t[0].y[0] = 2.25
t[0].d[0] = <5 bytes> 61 62 63 64 65
t[0].e[0] = 0
t[0].e[1] = 1
t[0].g[0] = -1.5
t[0].g[1] = 2.75
t[0].h[0] = <3 bytes> 78 79 7a
`)
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

	// types and enums of other types, by path; one of another schema keeps
	// its meta
	input = {2, 0x34, 0x12, 1, 0, 2, 0xaa, 0xbb, 7, 0xcc, 0xdd, 0xee, 0xff, 0x11}
	expect_dump(t, "paths", ksy_file_dump(t, "tests/schemas/imports/paths.ksy", nil, input), `paths[0].o[0].kind[0] = 2
paths[0].o[0].in[0].v[0] = 4660
paths[0].i[0].v[0] = 1
paths[0].k[0] = 2
paths[0].skipped[0] = <2 bytes> aa bb
paths[0].local[0].p[0] = 7
paths[0].by_enum[0] = <1 bytes> cc
paths[0].by_param[0] = <2 bytes> dd ee
paths[0].by_root[0] = <2 bytes> ff 11
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
		{DIR + "errors/parentless.ksy", .Invalid, DIR + "errors/parentless_lib.ksy", 14, 13, "if: _parent: o has no enclosing set here"},
		{DIR + "errors/rootless.ksy", .Invalid, DIR + "errors/rootless_lib.ksy", 20, 17, "if: _root: o is of a type of another schema, which has no _root here"},
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

	// a parse instance that nothing refers to is compiled once every set is,
	// as in Kaitai, where any instance can refer to any field: so in a type
	// inside the parse instance bg, one can use bg (_root.bg.sb), and one
	// can use a field of _parent after its own (_parent.body.len)
	enclosing := HEAD + `seq:
  - id: x
    type: u1
  - id: hdr
    type: hdr
  - id: body
    type: body
instances:
  bg:
    pos: 1
    type: bg
types:
  bg:
    seq:
      - id: sb
        type: u1
      - id: items
        type: item
    types:
      item:
        instances:
          v:
            pos: 0
            size: _root.bg.sb
  hdr:
    instances:
      peek:
        pos: 0
        size: _parent.body.len
  body:
    seq:
      - id: len
        type: u1
`
	expect_dump(t, "instances referring to later fields", ksy_dump(t, enclosing, {3, 2, 0xaa}), `t[0].x[0] = 3
t[0].hdr[0].peek[0] = <2 bytes> 03 02
t[0].body[0].len[0] = 2
t[0].bg[0].sb[0] = 2
t[0].bg[0].items[0].v[0] = <2 bytes> 03 02
`)

	// an instance without pos or value is read where its stream is, which
	// can only be one that reads nothing: a type of no fields, or size 0
	nopos := HEAD + `seq:
  - id: n
    type: u1
  - id: hdr
    type: hdr
    size: 3
  - id: tail
    size: 2
instances:
  flags:
    type: flags(n)
  marks:
    type: mark(_index)
    repeat: expr
    repeat-expr: n
  empty:
    size: 0
  far:
    io: hdr._io
    type: mark(9)
types:
  hdr:
    seq:
      - id: a
        type: u1
    instances:
      here:
        size: 0
      bits:
        type: flags(a)
  flags:
    params:
      - id: v
        type: u1
    instances:
      low:
        value: v & 1
      byte:
        pos: v
        type: u1
  mark:
    params:
      - id: i
        type: u1
    instances:
      at:
        pos: i % 3
        type: u1
`
	expect_dump(t, "instances without pos", ksy_dump(t, nopos, {2, 1, 0x20, 0x30, 0x40, 0x50}), `t[0].n[0] = 2
t[0].hdr[0].a[0] = 1
t[0].hdr[0].here[0] = <0 bytes>
t[0].hdr[0].bits[0].byte[0] = 32
t[0].tail[0] = <2 bytes> 40 50
t[0].flags[0].byte[0] = 32
t[0].marks[0].at[0] = 2
t[0].marks[1].at[0] = 1
t[0].empty[0] = <0 bytes>
t[0].far[0].at[0] = 1
`)

	// a parse instance of a set instance that has been read, first read by
	// an expression after it, is read as it would have been once that
	// instance was: at pos in its stream
	late := HEAD + "seq:\n  - id: a\n    type: s\n  - id: b\n    size: a.p\ntypes:\n  s:\n    seq:\n      - id: x\n        type: u1\n    instances:\n      p:\n        pos: 0\n        type: u1\n"
	expect_dump(t, "parse instance read late", ksy_dump(t, late, {2, 1, 0xaa, 0xbb}), "t[0].a[0].x[0] = 2\nt[0].a[0].p[0] = 2\nt[0].b[0] = <2 bytes> 01 aa\n")

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

// A repeat is an array however its count is written, as in Kaitai, also of
// one element, whose expressions have _index: a literal 1, 1 + 0, and a
// count read from the input as 1, beside counts of 0 and 2.
@(test)
ksy_repeat_of_one :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: n
    type: u1
  - id: lit
    type: u1
    repeat: expr
    repeat-expr: 1
  - id: lit_size
    size: lit.size
  - id: folded
    type: u1
    repeat: expr
    repeat-expr: 1 + 0
  - id: dyn
    type: u1
    repeat: expr
    repeat-expr: n
  - id: two
    type: u1
    repeat: expr
    repeat-expr: 2
  - id: sizes
    size: folded.size + dyn.size + two.size
  - id: indexed
    size: _index + 2
    repeat: expr
    repeat-expr: 1
  - id: one_item
    type: item
    repeat: expr
    repeat-expr: 1
  - id: item_ref
    size: one_item[0].v + one_item.size
  - id: valid_indexed
    type: u1
    repeat: expr
    repeat-expr: 1
    valid:
      expr: _ == lit[0] + _index
  - id: none
    type: u1
    repeat: expr
    repeat-expr: 0
  - id: none_size
    size: none.size + 1
types:
  item:
    seq:
      - id: v
        type: u1
`
	input := []byte{1, 7, 'A', 8, 9, 10, 11, 'B', 'B', 'B', 'B', 'C', 'C', 2, 'D', 'D', 'D', 7, 'E'}
	expect_dump(t, "repeat of one", ksy_dump(t, src, input), `t[0].n[0] = 1
t[0].lit[0] = 7
t[0].lit_size[0] = <1 bytes> 41
t[0].folded[0] = 8
t[0].dyn[0] = 9
t[0].two[0] = 10
t[0].two[1] = 11
t[0].sizes[0] = <4 bytes> 42 42 42 42
t[0].indexed[0] = <2 bytes> 43 43
t[0].one_item[0].v[0] = 2
t[0].item_ref[0] = <3 bytes> 44 44 44
t[0].valid_indexed[0] = 7
t[0].none_size[0] = <1 bytes> 45
`)
}

// Negative integer cases, written directly, as enum constants, and at the
// edges of an s8, choose as positive ones do.
@(test)
ksy_negative_cases :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: lit
    type:
      switch-on: -1
      cases:
        -1: u1
  - id: signs
    type: s1
    enum: sign
    repeat: expr
    repeat-expr: 2
  - id: by_enum
    type:
      switch-on: signs[_index]
      cases:
        sign::minus: u1
        sign::plus: u2
    repeat: expr
    repeat-expr: 2
  - id: recs
    type: rec
    repeat: expr
    repeat-expr: 5
types:
  rec:
    seq:
      - id: k
        type: s8
      - id: v
        type:
          switch-on: k
          cases:
            -1: u1
            -0x80: u2
            -9223372036854775808: s1
            9223372036854775807: s2
enums:
  sign:
    -1: minus
    1: plus
`
	input := []byte{
		1,
		0xff, 1, 2, 3, 4,
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 5,
		0x80, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 6, 0,
		0, 0, 0, 0, 0, 0, 0, 0x80, 0xf9,
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xf8, 0xff,
		1, 0, 0, 0, 0, 0, 0, 0,
	}
	expect_dump(t, "negative cases", ksy_dump(t, src, input), `t[0].lit[0] = 1
t[0].signs[0] = -1
t[0].signs[1] = 1
t[0].by_enum[0] = 2
t[0].by_enum[1] = 1027
t[0].recs[0].k[0] = -1
t[0].recs[0].v[0] = 5
t[0].recs[1].k[0] = -128
t[0].recs[1].v[0] = 6
t[0].recs[2].k[0] = -9223372036854775808
t[0].recs[2].v[0] = -7
t[0].recs[3].k[0] = 9223372036854775807
t[0].recs[3].v[0] = -8
t[0].recs[4].k[0] = 1
`)
}

// A value instance that reads a repeated field keeps the value it had when
// first used, as Kaitai keeps every value instance's, though the field
// grows after: in the valid of the field's elements, in their size, in its
// repeat-until, and reached through another value instance. One whose value
// is the field's array keeps the array, which grows.
@(test)
ksy_value_instance_kept :: proc(t: ^testing.T) {
	Case :: struct {
		name, src: string,
		input:     []byte,
		want:      string,
	}
	cases := [?]Case {
		{"valid", HEAD + `seq:
  - id: items
    type: u1
    repeat: expr
    repeat-expr: 3
    valid:
      expr: saved == 1
instances:
  saved: {value: items.size}
`, {1, 2, 3}, "t[0].items[0] = 1\nt[0].items[1] = 2\nt[0].items[2] = 3\n"},
		{"size", HEAD + `seq:
  - id: blocks
    size: first_size
    repeat: expr
    repeat-expr: 3
instances:
  first_size: {value: blocks.size + 1}
`, {'A', 'B', 'C'}, "t[0].blocks[0] = <1 bytes> 41\nt[0].blocks[1] = <1 bytes> 42\nt[0].blocks[2] = <1 bytes> 43\n"},
		{"repeat-until", HEAD + `seq:
  - id: vals
    type: u1
    repeat: until
    repeat-until: vals.size - started >= 2
instances:
  started: {value: vals.size}
`, {4, 5, 6, 7}, "t[0].vals[0] = 4\nt[0].vals[1] = 5\nt[0].vals[2] = 6\n"},
		{"through a value instance", HEAD + `seq:
  - id: more
    type: u1
    repeat: expr
    repeat-expr: 2
    valid:
      expr: me.more_seen == 1
instances:
  me: {value: _root}
  more_seen: {value: more.size}
`, {7, 8}, "t[0].more[0] = 7\nt[0].more[1] = 8\n"},
		// the array itself is kept as the field's, which grows, as Kaitai
		// keeps a reference to it, directly, through another value instance
		// and through ?:, while its size, a value of its own, is kept
		{"array", HEAD + `seq:
  - id: items
    type: u1
    repeat: expr
    repeat-expr: 3
    valid:
      expr: saved.size == _index + 1 and again.size == _index + 1 and pick.size == _index + 1 and count == 1
instances:
  saved: {value: items}
  again: {value: saved}
  pick: {value: 'saved.size > 0 ? items : [300, 300, 300, 300]'}
  count: {value: saved.size}
`, {1, 2, 3}, "t[0].items[0] = 1\nt[0].items[1] = 2\nt[0].items[2] = 3\n"},
	}
	for c in cases do expect_dump(t, c.name, ksy_dump(t, c.src, c.input), c.want)
}

// Each value instance that refers to others is evaluated once for its set
// instance, so a chain in which each refers to the one before twice takes
// as many evaluations as it has links, rather than doubling with each.
@(test)
ksy_value_instance_chain :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	LINKS :: 40
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, HEAD + "seq:\n  - id: n\n    type: u1\n  - id: data\n    size: v40 >> 40\ninstances:\n  v0: {value: n}\n")
	for i in 1 ..= LINKS do fmt.sbprintf(&b, "  v%d: {{value: v%d + v%d}}\n", i, i - 1, i - 1)
	expect_dump(t, "chain", ksy_dump(t, strings.to_string(b), {1, 'D'}), "t[0].n[0] = 1\nt[0].data[0] = <1 bytes> 44\n")
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

	// an endian that is a switch-on is chosen as each instance of its type
	// is read, in the instance (_root.bom), and the types declared in the
	// type take it (inner), but for one with its own (fixed); a parse
	// instance has its instance's, whether read once the root is (peek) or
	// by an expression (probe), and a case can be _
	orders := HEAD + `seq:
  - id: bom
    type: u1
  - id: bodies
    type: body
    repeat: expr
    repeat-expr: 2
  - id: probe
    size: (bodies[1].inner.peek & 3) + (bodies[0].via & 1)
  - id: sig
    size: 2
  - id: tagged
    type: tagged
types:
  body:
    meta:
      endian:
        switch-on: _root.bom
        cases:
          1: le
          2: be
    seq:
      - id: a
        type: u2
      - id: inner
        type: inner
      - id: fixed
        type: fixed
    instances:
      later:
        pos: 1
        type: u2
      via:
        value: inner.peek + 1
    types:
      inner:
        seq:
          - id: b
            type: u4
          - id: c
            type: u2le
        instances:
          peek:
            pos: 1
            type: u2
  fixed:
    meta:
      endian: be
    seq:
      - id: d
        type: u2
  tagged:
    meta:
      endian:
        switch-on: _root.sig
        cases:
          '[0x49, 0x49]': le
          _: be
    seq:
      - id: v
        type: u2
`
	expect_dump(t, "endian switch-on, le", ksy_dump(t, orders, {1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 48, 73, 73, 171, 205}), `t[0].bom[0] = 1
t[0].bodies[0].a[0] = 513
t[0].bodies[0].inner[0].b[0] = 100992003
t[0].bodies[0].inner[0].c[0] = 2055
t[0].bodies[0].inner[0].peek[0] = 513
t[0].bodies[0].fixed[0].d[0] = 2314
t[0].bodies[0].later[0] = 513
t[0].bodies[1].a[0] = 3083
t[0].bodies[1].inner[0].b[0] = 269422093
t[0].bodies[1].inner[0].c[0] = 4625
t[0].bodies[1].inner[0].peek[0] = 513
t[0].bodies[1].fixed[0].d[0] = 4884
t[0].bodies[1].later[0] = 513
t[0].probe[0] = <1 bytes> 30
t[0].sig[0] = <2 bytes> 49 49
t[0].tagged[0].v[0] = 52651
`)
	expect_dump(t, "endian switch-on, be", ksy_dump(t, orders, {2, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 48, 49, 50, 77, 77, 171, 205}), `t[0].bom[0] = 2
t[0].bodies[0].a[0] = 258
t[0].bodies[0].inner[0].b[0] = 50595078
t[0].bodies[0].inner[0].c[0] = 2055
t[0].bodies[0].inner[0].peek[0] = 258
t[0].bodies[0].fixed[0].d[0] = 2314
t[0].bodies[0].later[0] = 258
t[0].bodies[1].a[0] = 2828
t[0].bodies[1].inner[0].b[0] = 219025168
t[0].bodies[1].inner[0].c[0] = 4625
t[0].bodies[1].inner[0].peek[0] = 258
t[0].bodies[1].fixed[0].d[0] = 4884
t[0].bodies[1].later[0] = 258
t[0].probe[0] = <3 bytes> 30 31 32
t[0].sig[0] = <2 bytes> 4d 4d
t[0].tagged[0].v[0] = 43981
`)
	expect_dump(t, "endian switch-on, no case", ksy_dump(t, orders, {3, 1, 2}), "error: Undecided_Endianness at 1 in t[0].bodies[0]")
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
	// in a type that contains itself, an imported schema's _root is its
	// outermost instance at every depth, as in Kaitai: next is read while
	// the outermost n is not 0, until the input ends
	expect_dump(t, "imported _root, 0", ksy_file_dump(t, DIR + "imported_root.ksy", nil, {0, 7}), "imported_root[0].c[0].n[0] = 0\n")
	expect_dump(t, "imported _root, 1", ksy_file_dump(t, DIR + "imported_root.ksy", nil, {1, 0}), "error: Unexpected_EOF at 2 in imported_root[0].c[0].next[0].next[0].n[0]")

	// with parent: _parent, an entry inside an entry has the same _parent,
	// so the type can use it, also through the value instance that tail
	// reaches through first.next; contents reads its own length whatever
	// its size; and an instance without pos whose switch-on cases read
	// nothing is read where it is used
	parent := HEAD + `seq:
  - id: sec
    type: sec
  - id: magic
    contents: [0x11, 0x22]
    size: 5
  - id: flags
    type: u1
  - id: by_size
    size: magic_size
  - id: by_flags
    size: flags_obj.as<bits>.low
instances:
  flags_obj:
    type:
      switch-on: flags
      cases:
        1: bits(flags)
  magic_size:
    value: magic._sizeof
types:
  sec:
    seq:
      - id: n
        type: u1
      - id: first
        type: entry
      - id: tail
        size: first.next.scaled
  entry:
    seq:
      - id: v
        type: u1
      - id: has_next
        type: u1
      - id: next
        type: entry
        parent: _parent
        if: has_next != 0
      - id: w
        size: _parent.n
    instances:
      scaled:
        value: v * _parent.n
  bits:
    params:
      - id: value
        type: u1
    instances:
      low:
        value: value & 1
`
	expect_dump(t, "parent", ksy_dump(t, parent, {2, 1, 1, 3, 0, 0xaa, 0xbb, 0xcc, 0xdd, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x11, 0x22, 1, 0x77, 0x88, 0x99}), `t[0].sec[0].n[0] = 2
t[0].sec[0].first[0].v[0] = 1
t[0].sec[0].first[0].has_next[0] = 1
t[0].sec[0].first[0].next[0].v[0] = 3
t[0].sec[0].first[0].next[0].has_next[0] = 0
t[0].sec[0].first[0].next[0].w[0] = <2 bytes> aa bb
t[0].sec[0].first[0].w[0] = <2 bytes> cc dd
t[0].sec[0].tail[0] = <6 bytes> 11 22 33 44 55 66
t[0].magic[0] = <2 bytes> 11 22
t[0].flags[0] = 1
t[0].by_size[0] = <2 bytes> 77 88
t[0].by_flags[0] = <1 bytes> 99
`)
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

// Encodings: each one zelbyn decodes, by names in other cases and by
// aliases, as the official compiler finds them, from meta and from an
// attribute. A UTF-16 or UTF-32 sequence that is not a character is
// U+FFFD (odd, wide), and a byte-order mark is kept (bom). The bytes that
// windows-1251 and windows-1252 leave undefined are their own code points,
// as in WHATWG's tables. pad-right and the terminator apply to the bytes,
// before they are decoded, so a pad of 0 cuts UTF-16 mid-character, as in
// Kaitai (padded). Expressions see the text: valid compares it, switch-on
// chooses by it, and .length counts its code points.
@(test)
ksy_encodings :: proc(t: ^testing.T) {
	src := HEAD + `  encoding: UTF-16LE
seq:
  - id: le
    type: str
    size: 8
  - id: be
    type: str
    size: 4
    encoding: utf_16_be
    valid: '"Ωx"'
  - id: odd
    type: str
    size: 5
  - id: bom
    type: str
    size: 4
    encoding: utf16le
  - id: wide
    type: str
    size: 8
    encoding: UTF-32BE
  - id: latin
    type: str
    size: 3
    encoding: latin1
  - id: cyrillic
    type: str
    size: 3
    encoding: CP1251
  - id: western
    type: str
    size: 2
    encoding: windows-1252
  - id: dos
    type: strz
    encoding: IBM437
  - id: padded
    type: str
    size: 6
    pad-right: 0
  - id: body
    type:
      switch-on: le
      cases:
        '"Hé😀"': hit
  - id: len
    size: le.length
types:
  hit:
    seq:
      - id: v
        type: u1
`
	input := []byte{0x48, 0x00, 0xe9, 0x00, 0x3d, 0xd8, 0x00, 0xde, 0x03, 0xa9, 0x00, 0x78, 0x61, 0x00, 0x62, 0x00, 0x07, 0xff, 0xfe, 0x78, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x11, 0x00, 0x00, 0x80, 0xe9, 0xff, 0xc0, 0xe0, 0x98, 0x80, 0x81, 0xc9, 0xcd, 0xbb, 0x00, 0x6f, 0x00, 0x6b, 0x00, 0x00, 0x00, 0x2a, 0x4c, 0x4c, 0x4c}
	expect_dump(t, "json", ksy_json(t, src, input), `{"t":[{"le":["Hé\ud83d\ude00"],"be":["\u03a9x"],"odd":["ab\ufffd"],"bom":["\ufeffx"],"wide":["A\ufffd"],"latin":["\u0080éÿ"],"cyrillic":["\u0410\u0430\u0098"],"western":["\u20ac\u0081"],"dos":["\u2554\u2550\u2557"],"padded":["o\ufffd"],"body":[{"v":[42]}],"len":["4c4c4c"]}]}` + "\n")
	text := ksy_dump(t, src, input)
	testing.expectf(t, strings.has_prefix(text, "t[0].le[0] = \"Hé\\U0001f600\"\nt[0].be[0] = \"\\u03a9x\"\n"), "text: %q", text[:min(len(text), 60)])
	wrong := slice.clone(input, context.temp_allocator)
	wrong[9] = 0xaa
	expect_dump(t, "valid on text", ksy_dump(t, src, wrong), "error: Not_Equal at 8 in t[0].be[0]")
}

// switch-on, as the official compiler reads it: a repeated one without a _
// case or a length adds no value for an element that no case chooses, so
// it can have fewer values than elements, whose _index still counts every
// element (nums, recs, picks); one over a boolean chooses by true and false
// (by_flag); and a field whose cases all have values of one type can be
// used in expressions, as that type (sized, tail). In repeat-until, an
// element that no case chose leaves _ with no value, and each element but
// the last must still consume input.
@(test)
ksy_switch_on_limits :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: flag
    type: u1
  - id: kinds
    type: u1
    repeat: expr
    repeat-expr: 4
  - id: nums
    type:
      switch-on: kinds[_index]
      cases:
        1: u1
        2: u2
    repeat: expr
    repeat-expr: 4
  - id: recs
    type:
      switch-on: kinds[_index]
      cases:
        1: rec
    repeat: expr
    repeat-expr: 4
  - id: by_flag
    type:
      switch-on: flag == 1
      cases:
        true: u2
        false: u1
  - id: sized
    size: by_flag
  - id: picks
    type:
      switch-on: _index
      cases:
        0: u1
        1: b4
    repeat: until
    repeat-until: _index == 2
  - id: tail
    size: 'nums.size + nums[1] % 4 + (by_flag > 2 ? 1 : 0)'
types:
  rec:
    seq:
      - id: v
        type: u1
`
	expect_dump(t, "flag set", ksy_dump(t, src, {0x01, 0x01, 0x09, 0x02, 0x01, 0x11, 0x34, 0x12, 0x22, 0xa1, 0xa2, 0x03, 0x00, 0xe0, 0xe1, 0xe2, 0x07, 0xf5, 0x51, 0x52, 0x53, 0x54}), `t[0].flag[0] = 1
t[0].kinds[0] = 1
t[0].kinds[1] = 9
t[0].kinds[2] = 2
t[0].kinds[3] = 1
t[0].nums[0] = 17
t[0].nums[1] = 4660
t[0].nums[2] = 34
t[0].recs[0].v[0] = 161
t[0].recs[1].v[0] = 162
t[0].by_flag[0] = 3
t[0].sized[0] = <3 bytes> e0 e1 e2
t[0].picks[0] = 7
t[0].picks[1] = 15
t[0].tail[0] = <4 bytes> 51 52 53 54
`)
	expect_dump(t, "flag clear", ksy_dump(t, src, {0x00, 0x09, 0x02, 0x09, 0x01, 0x01, 0x02, 0x05, 0x99, 0x02, 0xc0, 0xc1, 0x07, 0x35, 0x61, 0x62, 0x63}), `t[0].flag[0] = 0
t[0].kinds[0] = 9
t[0].kinds[1] = 2
t[0].kinds[2] = 9
t[0].kinds[3] = 1
t[0].nums[0] = 513
t[0].nums[1] = 5
t[0].recs[0].v[0] = 153
t[0].by_flag[0] = 2
t[0].sized[0] = <2 bytes> c0 c1
t[0].picks[0] = 7
t[0].picks[1] = 3
t[0].tail[0] = <3 bytes> 61 62 63
`)

	until := HEAD + "seq:\n  - id: xs\n    type:\n      switch-on: _index\n      cases:\n        0: u1\n    repeat: until\n    repeat-until: _ == 0\n"
	expect_dump(t, "_ of no case", ksy_dump(t, until, {5, 6}), "error: Absent_Field at 1 in t[0]")
	stuck := HEAD + "seq:\n  - id: xs\n    type:\n      switch-on: _index\n      cases:\n        1: u1\n    repeat: until\n    repeat-until: _index == 3\n"
	expect_dump(t, "no progress", ksy_dump(t, stuck, {5, 6}), "error: No_Progress at 0 in t[0].xs[0]")
}

// Value instances of sets (first, an element; picked, whose own instance
// total uses _parent; word0, a cast), of byte arrays (raw) and of arrays
// (vals), and casts: to an integer type, which leaves the value as it is,
// and to a user type, of a switch-on field, which gives its fields; one of
// an instance read as another case is Wrong_Type. A case's instance can
// cast the field to a case after it (byte_val's as_word). A value
// instance can refer to a field after its set's (later), and a parse
// instance that no expression reads is read once the root is, so it can
// use an element of its array read after it (body), as in Kaitai.
@(test)
ksy_value_instances_and_casts :: proc(t: ^testing.T) {
	src := HEAD + `seq:
  - id: n
    type: u1
  - id: recs
    type: rec
    repeat: expr
    repeat-expr: 2
  - id: blob
    size: 2
  - id: nums
    type: u1
    repeat: expr
    repeat-expr: 3
  - id: entries
    type: entry
    repeat: expr
    repeat-expr: 2
  - id: by_first
    size: first.v
  - id: by_picked
    size: picked.total
  - id: by_raw
    size: raw.size + raw[1]
  - id: by_vals
    size: vals.size + vals.max - vals[0]
  - id: by_cast
    size: entries[0].body.as<word>.w.as<u2> - 0x100
  - id: by_word
    size: word0.w - 0x101
  - id: items
    type: item(_index)
    repeat: expr
    repeat-expr: 2
  - id: by_later
    size: recs[0].later - 1
instances:
  first:
    value: recs[0]
  picked:
    value: recs[n % 2]
  raw:
    value: blob
  vals:
    value: nums
  word0:
    value: entries[0].body.as<word>
types:
  rec:
    seq:
      - id: v
        type: u1
    instances:
      total:
        value: v + _parent.n
      later:
        value: _parent.items.size
  entry:
    seq:
      - id: kind
        type: u1
      - id: body
        type:
          switch-on: kind
          cases:
            1: byte_val
            2: word
  byte_val:
    seq:
      - id: b
        type: u1
    instances:
      as_word:
        value: _parent.body.as<word>
  word:
    seq:
      - id: w
        type: u2
  item:
    params:
      - id: i
        type: u1
    seq:
      - id: ofs
        type: u1
    instances:
      len_body:
        value: _parent.items[i + 1].ofs - ofs
      body:
        pos: ofs
        size: len_body
        if: i == 0
`
	input := []byte{0x01, 0x02, 0x03, 0xaa, 0x02, 0x04, 0x09, 0x05, 0x02, 0x02, 0x01, 0x01, 0x77, 0x46, 0x46, 0x50, 0x50, 0x50, 0x50, 0x52, 0x52, 0x52, 0x52, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x56, 0x43, 0x43, 0x57, 0x00, 0x03, 0x4c}
	expect_dump(t, "values and casts", ksy_dump(t, src, input), `t[0].n[0] = 1
t[0].recs[0].v[0] = 2
t[0].recs[1].v[0] = 3
t[0].blob[0] = <2 bytes> aa 02
t[0].nums[0] = 4
t[0].nums[1] = 9
t[0].nums[2] = 5
t[0].entries[0].kind[0] = 2
t[0].entries[0].body[0].w[0] = 258
t[0].entries[1].kind[0] = 1
t[0].entries[1].body[0].b[0] = 119
t[0].by_first[0] = <2 bytes> 46 46
t[0].by_picked[0] = <4 bytes> 50 50 50 50
t[0].by_raw[0] = <4 bytes> 52 52 52 52
t[0].by_vals[0] = <8 bytes> 56 56 56 56 56 56 56 56
t[0].by_cast[0] = <2 bytes> 43 43
t[0].by_word[0] = <1 bytes> 57
t[0].items[0].ofs[0] = 0
t[0].items[0].body[0] = <3 bytes> 01 02 03
t[0].items[1].ofs[0] = 3
t[0].by_later[0] = <1 bytes> 4c
`)
	wrong := slice.clone(input, context.temp_allocator)
	wrong[8] = 1
	expect_dump(t, "cast to another case", ksy_dump(t, src, wrong), "error: Wrong_Type at 30 in t[0].by_cast[0]")
}

// Array literals: one of integer literals from 0 to 255 is a byte array,
// compared byte by byte (is_pk, sorted) and in valid with an expression
// (alt); others are arrays of integers (big), strings (names_len),
// booleans (flags) and byte arrays (table), indexed, measured and with
// their methods (arr_ops).
@(test)
ksy_array_literals :: proc(t: ^testing.T) {
	src := HEAD + `  encoding: ASCII
seq:
  - id: magic
    size: 2
    valid:
      any-of: ['[0x50, 0x4b]', alt]
  - id: n
    type: u1
  - id: is_pk
    size: 'magic == [0x50, 0x4b] ? 1 : 2'
  - id: table_pick
    size: table[n].size + table[n][1]
  - id: big
    size: '[1, 300, 2][n] % 7'
  - id: names_len
    size: '["ab", "cde"][n].length'
  - id: sorted
    size: 'magic < [0x50, 0x4c] ? 3 : 4'
  - id: flags
    size: '[true, false][n] ? 1 : 5'
  - id: arr_ops
    size: '[3, 1, 400].max - 397 + [9, 8, 7].size'
instances:
  alt:
    value: '[0x4d, 0x5a]'
  table:
    value: |
      [
        [0x00, 0x01],
        [0x02, 0x03, 0x04],
      ]
`
	expect_dump(t, "PK", ksy_dump(t, src, {0x50, 0x4b, 0x01, 0x49, 0x54, 0x54, 0x54, 0x54, 0x54, 0x54, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x4e, 0x4e, 0x4e, 0x53, 0x53, 0x53, 0x46, 0x46, 0x46, 0x46, 0x46, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41}), `t[0].magic[0] = <2 bytes> 50 4b
t[0].n[0] = 1
t[0].is_pk[0] = <1 bytes> 49
t[0].table_pick[0] = <6 bytes> 54 54 54 54 54 54
t[0].big[0] = <6 bytes> 42 42 42 42 42 42
t[0].names_len[0] = <3 bytes> 4e 4e 4e
t[0].sorted[0] = <3 bytes> 53 53 53
t[0].flags[0] = <5 bytes> 46 46 46 46 46
t[0].arr_ops[0] = <6 bytes> 41 41 41 41 41 41
`)
	expect_dump(t, "MZ", ksy_dump(t, src, {0x4d, 0x5a, 0x00, 0x49, 0x49, 0x54, 0x54, 0x54, 0x42, 0x4e, 0x4e, 0x53, 0x53, 0x53, 0x53, 0x46, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41}), `t[0].magic[0] = <2 bytes> 4d 5a
t[0].n[0] = 0
t[0].is_pk[0] = <2 bytes> 49 49
t[0].table_pick[0] = <3 bytes> 54 54 54
t[0].big[0] = <1 bytes> 42
t[0].names_len[0] = <2 bytes> 4e 4e
t[0].sorted[0] = <3 bytes> 53 53 53
t[0].flags[0] = <1 bytes> 53
t[0].arr_ops[0] = <6 bytes> 46 41 41 41 41 41
`)
	expect_dump(t, "neither", ksy_dump(t, src, {'P', 'Z', 0}), "error: Not_Any_Of at 0 in t[0].magic[0]")

	// array literals of arrays, indexed at every depth, whole (.first,
	// .last) and through a value instance; [1, 2] in them is bytes
	arrays := HEAD + `seq:
  - id: k
    type: u1
  - id: a
    size: (table[k][1] * 4).to_i
  - id: b
    size: row.first.to_i
  - id: c
    size: words[k].size
  - id: d
    size: words[0][1].length
  - id: e
    size: nested[1][0][1]
  - id: f
    size: table.last[0].to_i
instances:
  table:
    value: '[[0.5, 1], [1.5, 0.75]]'
  row:
    value: table[k]
  words:
    value: "[['a', 'bb'], ['ccc']]"
  nested:
    value: '[[[1, 2]], [[3, 4], [5, 6]]]'
`
	expect_dump(t, "arrays of arrays", ksy_dump(t, arrays, transmute([]byte)string("\x01AAABCDDEEEEF")), `t[0].k[0] = 1
t[0].a[0] = <3 bytes> 41 41 41
t[0].b[0] = <1 bytes> 42
t[0].c[0] = <1 bytes> 43
t[0].d[0] = <2 bytes> 44 44
t[0].e[0] = <4 bytes> 45 45 45 45
t[0].f[0] = <1 bytes> 46
`)
}

// to-string, at the top level and in a type, is parsed and otherwise
// ignored: as in the official compiler, its names are not resolved.
@(test)
ksy_to_string :: proc(t: ^testing.T) {
	src := HEAD + "seq:\n  - id: a\n    type: s\nto-string: '\"t\" + a.v.to_s'\ntypes:\n  s:\n    seq:\n      - id: v\n        type: u1\n    to-string: no_such_field\n"
	expect_dump(t, "to-string", ksy_dump(t, src, {7}), "t[0].a[0].v[0] = 7\n")
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

	// a param of a user type is the instance its argument gives, whose
	// fields, value instances and parse instances it reaches, these read
	// as they would have been once that instance was; and a str param
	user := HEAD + `seq:
  - id: hdrs
    type: hdr
    repeat: expr
    repeat-expr: 2
  - id: bodies
    type: body(hdrs[_index], 'x' + hdrs[_index].tag)
    repeat: expr
    repeat-expr: 2
  - id: sw
    type:
      switch-on: hdrs[0].n
      cases:
        1: body(hdrs[1], 'y')
types:
  hdr:
    seq:
      - id: n
        type: u1
      - id: tag
        type: str
        size: 1
        encoding: ASCII
    instances:
      twice:
        value: n * 2
      peek:
        pos: 0
        type: u1
      inner:
        pos: 0
        type: inner
    types:
      inner:
        seq:
          - id: v
            type: u1
        instances:
          up:
            value: _parent.n + v
  body:
    params:
      - id: h
        type: hdr
      - id: name
        type: str
    seq:
      - id: data
        size: h.twice
      - id: more
        size: h.peek + h.inner.up
        if: name == 'xb'
`
	expect_dump(t, "params of a user type", ksy_dump(t, user, {1, 'a', 2, 'b', 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99}), `t[0].hdrs[0].n[0] = 1
t[0].hdrs[0].tag[0] = "a"
t[0].hdrs[0].peek[0] = 1
t[0].hdrs[0].inner[0].v[0] = 1
t[0].hdrs[1].n[0] = 2
t[0].hdrs[1].tag[0] = "b"
t[0].hdrs[1].peek[0] = 1
t[0].hdrs[1].inner[0].v[0] = 1
t[0].bodies[0].data[0] = <2 bytes> aa bb
t[0].bodies[1].data[0] = <4 bytes> cc dd ee ff
t[0].bodies[1].more[0] = <4 bytes> 11 22 33 44
t[0].sw[0].data[0] = <4 bytes> 55 66 77 88
`)

	// the params of the top-level type of the schema decoded take the
	// arguments given to the decoder, one of each param's type, which the
	// tree copies
	top := HEAD + `params:
  - id: n
    type: u1
  - id: twice
    type: bool
  - id: tag
    type: bytes
  - id: name
    type: str
seq:
  - id: a
    size: 'n * (twice ? 2 : 1)'
  - id: b
    size: tag.size
    if: name == "x"
`
	{
		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		err := ksy.compile(top, &ff)
		defer ksy.destroy_error(&err)
		if testing.expectf(t, err.kind == .None, "compile: %s", err.message) {
			tag := []byte{1, 2, 3}
			expect_dump(t, "top-level params", dump_decoded(t, &ff, {1, 2, 3, 4, 5, 6, 7}, {i64(2), true, tag, "x"}), "t[0].a[0] = <4 bytes> 01 02 03 04\nt[0].b[0] = <3 bytes> 05 06 07\n")
			expect_dump(t, "top-level params, other", dump_decoded(t, &ff, {1, 2, 3}, {i64(1), false, tag, "y"}), "t[0].a[0] = <1 bytes> 01\n")
			expect_dump(t, "top-level params, none", dump_decoded(t, &ff, {1}), "error: Invalid_Arguments at 0 in ")
			expect_dump(t, "top-level params, wrong type", dump_decoded(t, &ff, {1}, {i64(1), i64(1), tag, "y"}), "error: Invalid_Arguments at 0 in ")
		}
	}
	{
		// arguments for a schema whose top-level type has no params
		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		err := ksy.compile(HEAD + "seq:\n  - id: a\n    type: u1\n", &ff)
		defer ksy.destroy_error(&err)
		if testing.expectf(t, err.kind == .None, "compile: %s", err.message) {
			expect_dump(t, "arguments without params", dump_decoded(t, &ff, {1}, {i64(1)}), "error: Invalid_Arguments at 0 in ")
		}
	}
	{
		// a param of a user type on the top-level type is given bytes, read
		// as an instance of it in a stream of their own, whose _io a parse
		// instance reads; also _io of a param of a type, and ?: on arrays
		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)
		err := ksy.compile(HEAD + `params:
  - id: hp
    type: hdr
seq:
  - id: x
    size: hp.a
  - id: h
    type: hdr
  - id: u
    type: user(h)
  - id: k
    type: u1
  - id: xs
    type: u1
    repeat: expr
    repeat-expr: 3
  - id: y
    size: '(k == 0 ? xs : ys).size'
  - id: z
    size: '(k == 0 ? ys : xs)[0] - 9'
instances:
  via_io:
    io: hp._io
    pos: 1
    type: u1
  ys:
    value: '[10, 300]'
types:
  hdr:
    seq:
      - id: a
        type: u1
      - id: b
        type: u1
  user:
    params:
      - id: p
        type: hdr
    instances:
      q:
        io: p._io
        pos: 0
        type: u1
`, &ff)
		defer ksy.destroy_error(&err)
		if testing.expectf(t, err.kind == .None, "compile: %s", err.message) {
			input := transmute([]byte)string("XX\x05\x06\x00\x01\x02\x03YYYZ")
			expect_dump(t, "user-type top-level param", dump_decoded(t, &ff, input, {[]byte{2, 7}}), `t[0].x[0] = <2 bytes> 58 58
t[0].h[0].a[0] = 5
t[0].h[0].b[0] = 6
t[0].u[0].q[0] = 88
t[0].k[0] = 0
t[0].xs[0] = 1
t[0].xs[1] = 2
t[0].xs[2] = 3
t[0].y[0] = <3 bytes> 59 59 59
t[0].z[0] = <1 bytes> 5a
t[0].via_io[0] = 7
`)
			expect_dump(t, "user-type top-level param, short", dump_decoded(t, &ff, input, {[]byte{2}}), "error: Unexpected_EOF at 1 in hp[0].b[0]")
			expect_dump(t, "user-type top-level param, not bytes", dump_decoded(t, &ff, input, {i64(2)}), "error: Invalid_Arguments at 0 in ")
		}
	}

	// _sizeof needs only the type of a parse instance, so the value
	// instance that gives its pos can use it, as mcap.ksy does
	sized := HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  rec:\n    pos: ofs\n    type: r\n  ofs:\n    value: _io.size - rec.x._sizeof - 1\ntypes:\n  r:\n    seq:\n      - id: x\n        type: u2\n"
	expect_dump(t, "_sizeof in pos", ksy_dump(t, sized, {9, 1, 2, 3}), "t[0].a[0] = 9\nt[0].rec[0].x[0] = 513\n")

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
