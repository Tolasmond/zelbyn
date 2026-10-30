package tests

import arn "../zelbyn/arena"
import expr "../zelbyn/expression"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import yml "../zelbyn/yaml"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// What a decode may take (reader.Limits), and how deeply YAML, expressions
// and a schema's types and instances may nest (yaml.MAX_NESTING,
// expression.MAX_DEPTH and MAX_CHAIN, ksy.MAX_NESTING): each input either
// decodes, or fails with the limit it reached, at its limit and one past.

@(private = "file")
LIMITS_HEAD :: "meta:\n  id: t\n  endian: le\n"

// The result of decoding input with src and limits, "ok" or "error: <kind>
// in <path>", or the compile error, and the bytes the tree's arena held
// beyond the input. With from_file, read decodes it from a temporary file,
// which it puts in the arena too, named by the test (see temp_file in
// cli_test.odin).
@(private = "file")
decode_limited :: proc(t: ^testing.T, src: string, input: []byte, limits: rdr.Limits, from_file := false, loc := #caller_location) -> (result: string, used: uint) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	cerr := ksy.compile(src, &ff)
	defer ksy.destroy_error(&cerr)
	if cerr.kind != .None do return fmt.tprintf("compile: %v: %s", cerr.kind, cerr.message), 0

	tree: fld.Value_Tree
	defer fld.destroy_value_tree(&tree)
	err: rdr.Parse_Error
	if from_file {
		f, create_err := os.create_temp_file("", fmt.tprintf("zelbyn_%s_*.bin", loc.procedure))
		if create_err != nil do return fmt.tprintf("creating a temporary file: %v", create_err), 0
		path := strings.clone(os.name(f), context.temp_allocator)
		_, write_err := os.write(f, input)
		os.close(f)
		defer os.remove(path)
		if write_err != nil do return fmt.tprintf("writing %s: %v", path, write_err), 0
		_, err = rdr.read(path, &ff, &tree, limits = limits)
		used = arn.arena_used(&tree.arena) - uint(len(input))
	} else {
		_, err = rdr.read_from_bytes(input, &ff, &tree, limits = limits)
		used = arn.arena_used(&tree.arena)
	}
	defer rdr.destroy_parse_error(&err)
	if err.kind == .None do return "ok", used
	check_failed_tree(&ff, input, "", err, &tree, false, nil, limits)
	return fmt.tprintf("error: %v in %s", err.kind, err.path), used
}

// The kind of the error compiling src gives, and its message; .None when it
// compiles.
@(private = "file")
compile_kind :: proc(src: string) -> (kind: ksy.Error_Kind, message: string) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	return err.kind, strings.clone(err.message, context.temp_allocator)
}

// A count read from the input, 2^32 - 1, of elements that read nothing: of
// a type with no fields, each an instance, they fill max_memory, and fail
// with Memory_Limit, or with no memory limit, take max_steps; of a
// switch-on that no case chooses, which add no value, they allocate
// nothing and take the steps.
@(test)
limits_huge_counts :: proc(t: ^testing.T) {
	count := []byte{0xff, 0xff, 0xff, 0xff}
	empties := LIMITS_HEAD + "seq:\n  - id: n\n    type: u4\n  - id: e\n    type: empty\n    repeat: expr\n    repeat-expr: n\ntypes:\n  empty: {}\n"
	result, used := decode_limited(t, empties, count, {max_memory = 1 << 20})
	testing.expectf(t, strings.has_prefix(result, "error: Memory_Limit in t[0]"), "empty instances, 1 MB: %s", result)
	testing.expectf(t, used <= 1 << 20 + arn.COMMIT_SIZE, "empty instances: the arena held %v bytes", used)
	result, _ = decode_limited(t, empties, count, {max_steps = 1000})
	testing.expect_value(t, result, "error: Step_Limit in t[0].e[998]")

	unchosen := LIMITS_HEAD + "seq:\n  - id: n\n    type: u4\n  - id: x\n    type:\n      switch-on: 2\n      cases:\n        1: u1\n    repeat: expr\n    repeat-expr: n\n"
	result, used = decode_limited(t, unchosen, count, {max_steps = 100_000})
	testing.expect_value(t, result, "error: Step_Limit in t[0].x[99998]")
	testing.expectf(t, used < 64 * 1024, "elements that add no value took %v bytes", used)
}

// The steps a decode takes, as Limits says: one for each element read, set
// instance and parse instance among them, the root's instance too, each
// value instance evaluated, and each item of an array literal made; a decode within them succeeds,
// and one with a step fewer fails at the field that took it.
@(test)
limits_steps_counted :: proc(t: ^testing.T) {
	Case :: struct {
		name, src: string,
		input:     []byte,
		steps:     int,
		past:      string, // the error with one step fewer
	}
	cases := [?]Case {
		{"three fields", LIMITS_HEAD + "seq:\n  - id: a\n    type: u1\n  - id: b\n    type: u1\n  - id: c\n    type: u1\n", {1, 2, 3}, 4, "error: Step_Limit in t[0].c[0]"},
		{"a repeat", LIMITS_HEAD + "seq:\n  - id: a\n    type: u1\n    repeat: expr\n    repeat-expr: 4\n", {1, 2, 3, 4}, 5, "error: Step_Limit in t[0].a[3]"},
		{"a set instance and its field", LIMITS_HEAD + "seq:\n  - id: s\n    type: inner\ntypes:\n  inner:\n    seq:\n      - id: v\n        type: u1\n", {1}, 3, "error: Step_Limit in t[0].s[0].v[0]"},
		{"a parse instance", LIMITS_HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n  p:\n    pos: 0\n    type: u1\n", {1}, 3, "error: Step_Limit in t[0].p[0]"},
		{"a value instance", LIMITS_HEAD + "seq:\n  - id: a\n    type: u1\n  - id: b\n    type: u1\n    valid:\n      expr: v == 2\ninstances:\n  v:\n    value: a + 1\n", {1, 0}, 4, "error: Step_Limit in t[0].b[0]"},
		{"an array literal", LIMITS_HEAD + "seq:\n  - id: a\n    type: u1\n    valid:\n      expr: '[_, 300, 400].size == 3'\n", {1}, 5, "error: Step_Limit in t[0].a[0]"},
	}
	for c in cases {
		result, _ := decode_limited(t, c.src, c.input, {max_steps = c.steps})
		testing.expectf(t, result == "ok", "%s, %v steps: %s", c.name, c.steps, result)
		result, _ = decode_limited(t, c.src, c.input, {max_steps = c.steps - 1})
		testing.expectf(t, result == c.past, "%s, %v steps: %s, want %s", c.name, c.steps - 1, result, c.past)
	}

	// a chain that would double with each link takes a step for each
	chain := strings.builder_make(context.temp_allocator)
	strings.write_string(&chain, LIMITS_HEAD + "seq:\n  - id: n\n    type: u1\n  - id: c\n    type: u1\n    valid:\n      expr: v31 > 0\ninstances:\n  v0: {value: n}\n")
	for i in 1 ..= 31 do fmt.sbprintf(&chain, "  v%d: {{value: v%d + v%d}}\n", i, i - 1, i - 1)
	result, _ := decode_limited(t, strings.to_string(chain), {1, 0}, {max_steps = 1000})
	testing.expect_value(t, result, "ok")
}

// max_memory bounds what the tree holds beyond the input, which is never
// more: a decode within it succeeds, and one under it fails with
// Memory_Limit, from the input or from a file, also once the file's block
// has committed more than the limit leaves.
@(test)
limits_memory :: proc(t: ^testing.T) {
	src := LIMITS_HEAD + "seq:\n  - id: items\n    type: item\n    repeat: eos\ntypes:\n  item:\n    seq:\n      - id: v\n        type: u1\n"
	input := make([]byte, 20_000, context.temp_allocator)
	for from_file in ([]bool{false, true}) {
		result, needed := decode_limited(t, src, input, {}, from_file)
		if !testing.expectf(t, result == "ok", "from a file %v: %s", from_file, result) do continue
		result, _ = decode_limited(t, src, input, {max_memory = int(needed)}, from_file)
		testing.expectf(t, result == "ok", "from a file %v, with the memory it needs, %v: %s", from_file, needed, result)
		used: uint
		result, used = decode_limited(t, src, input, {max_memory = int(needed / 4)}, from_file)
		testing.expectf(t, strings.has_prefix(result, "error: Memory_Limit in t[0].items["), "from a file %v, with a quarter of it: %s", from_file, result)
		testing.expectf(t, used <= needed / 4, "from a file %v, with a quarter: the arena held %v bytes, past %v", from_file, used, needed / 4)
	}

	// 8 MiB read into a block that commits half as much again as it holds,
	// and instances that take no input
	empties := LIMITS_HEAD + "seq:\n  - id: items\n    type: empty\n    repeat: expr\n    repeat-expr: 20000000\ntypes:\n  empty: {}\n"
	big := make([]byte, 8 << 20, context.temp_allocator)
	for from_file in ([]bool{false, true}) {
		result, used := decode_limited(t, empties, big, {max_memory = 1 << 20, max_steps = 1_000_000}, from_file)
		testing.expectf(t, strings.has_prefix(result, "error: Memory_Limit in t[0].items["), "8 MiB, from a file %v: %s", from_file, result)
		testing.expectf(t, used <= 1 << 20, "8 MiB, from a file %v: the arena held %v bytes beyond the input", from_file, used)
	}
}

// The decoder's own records are bounded by max_memory too: parse instances
// kept to be read once the root is, which read nothing when their if is
// false, and so take no steps.
@(test)
limits_kept_records :: proc(t: ^testing.T) {
	src := strings.builder_make(context.temp_allocator)
	strings.write_string(&src, LIMITS_HEAD + "instances:\n")
	for i in 0 ..< 10_000 do fmt.sbprintf(&src, "  p%d: {{pos: 0, type: u1, if: false}}\n", i)
	result, needed := decode_limited(t, strings.to_string(src), nil, {})
	if !testing.expect_value(t, result, "ok") do return
	used: uint
	result, used = decode_limited(t, strings.to_string(src), nil, {max_memory = int(needed / 4), max_steps = 1})
	testing.expect_value(t, result, "error: Memory_Limit in t[0]")
	testing.expectf(t, used <= needed / 4, "the arena held %v bytes, past %v", used, needed / 4)
}

// A YAML document nested MAX_NESTING deep parses, and one a level deeper,
// or 100,000 deep, flow or block, is Unsupported, without the parser's
// recursion using the stack up.
@(test)
limits_yaml_nesting :: proc(t: ^testing.T) {
	flow :: proc(n: int) -> string {
		return strings.concatenate({"a: ", strings.repeat("[", n - 1, context.temp_allocator), "x", strings.repeat("]", n - 1, context.temp_allocator), "\n"}, context.temp_allocator)
	}
	block :: proc(n: int) -> string {
		return strings.concatenate({strings.repeat("- ", n, context.temp_allocator), "x\n"}, context.temp_allocator)
	}
	// the map a: is a level
	Case :: struct {
		src:  string,
		kind: yml.Error_Kind,
	}
	cases := [?]Case {
		{flow(yml.MAX_NESTING), .None},
		{flow(yml.MAX_NESTING + 1), .Unsupported},
		{flow(100_000), .Unsupported},
		{block(yml.MAX_NESTING), .None},
		{block(yml.MAX_NESTING + 1), .Unsupported},
		{block(100_000), .Unsupported},
	}
	for c, i in cases {
		doc: yml.Document
		err := yml.parse(c.src, &doc)
		testing.expectf(t, err.kind == c.kind, "case %v (%v bytes): %v %s", i, len(c.src), err.kind, err.message)
		if c.kind != .None do testing.expectf(t, strings.contains(err.message, "nested more than"), "case %v: %s", i, err.message)
		yml.destroy_error(&err)
		yml.destroy_document(&doc)
	}
}

// An expression MAX_DEPTH deep parses, and one a level deeper, by unary
// operators, a chain of binary ones, which the parser builds without
// recursing, or parentheses, which make no node but nest as deep, is
// Unsupported, also 100,000 deep.
@(test)
limits_expression_depth :: proc(t: ^testing.T) {
	negations :: proc(n: int) -> string {
		return strings.concatenate({strings.repeat("-", n - 1, context.temp_allocator), "1"}, context.temp_allocator)
	}
	sums :: proc(n: int) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "1")
		for _ in 1 ..< n do strings.write_string(&b, " + 1")
		return strings.to_string(b)
	}
	parens :: proc(n: int) -> string {
		return strings.concatenate({strings.repeat("(", n - 1, context.temp_allocator), "1", strings.repeat(")", n - 1, context.temp_allocator)}, context.temp_allocator)
	}
	Case :: struct {
		text: string,
		ok:   bool,
	}
	cases := [?]Case {
		{negations(expr.MAX_DEPTH), true},
		{negations(expr.MAX_DEPTH + 1), false},
		{negations(100_000), false},
		{sums(expr.MAX_DEPTH), true},
		{sums(expr.MAX_DEPTH + 1), false},
		{sums(100_000), false},
		{parens(expr.MAX_DEPTH), true},
		{parens(expr.MAX_DEPTH + 1), false},
		{parens(100_000), false},
	}
	for c, i in cases {
		e, err := expr.parse(c.text, context.temp_allocator)
		testing.expectf(t, (err.kind == .None) == c.ok, "case %v (%v bytes): %v %s", i, len(c.text), err.kind, err.message)
		if !c.ok do testing.expectf(t, err.kind == .Unsupported && strings.contains(err.message, "nested more than"), "case %v: %v %s", i, err.kind, err.message)
		if c.ok do testing.expect(t, e != nil)
		expr.destroy_error(&err)
	}

	// valid: any-of of many values is no deeper than their logarithm
	any_of := strings.builder_make(context.temp_allocator)
	strings.write_string(&any_of, LIMITS_HEAD + "seq:\n  - id: n\n    type: u1\n  - id: a\n    type: u1\n    valid:\n      any-of:\n")
	for i in 0 ..< 10_000 do fmt.sbprintf(&any_of, "        - n + %v\n", i)
	result, _ := decode_limited(t, strings.to_string(any_of), {0, 200}, {})
	testing.expect_value(t, result, "ok")
}

// Types, instances and imports compiled inside each other MAX_NESTING deep
// compile, and a chain a link longer, or 100,000 long, of types whose field
// is of the next, of parse instances whose pos uses the next, or of
// sizeof<t> through such types, is Unsupported; so is a chain of value
// instances, each using the next, longer than MAX_CHAIN, whatever order
// it is compiled in. Each of 100,000 types or instances takes time linear
// in their number: in a mapping, their keys were each compared with every
// other, which took minutes.
@(test)
limits_compile_nesting :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	// a field of type t0, whose field is of t1, ..., down to t(n - 1)
	types :: proc(n: int, size_of: bool) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, LIMITS_HEAD + "seq:\n  - id: a\n")
		strings.write_string(&b, size_of ? "    size: sizeof<t0>\n" : "    type: t0\n")
		strings.write_string(&b, "types:\n")
		for i in 0 ..< n - 1 do fmt.sbprintf(&b, "  t%d:\n    seq:\n      - id: x\n        type: t%d\n", i, i + 1)
		fmt.sbprintf(&b, "  t%d:\n    seq:\n      - id: x\n        type: u1\n", n - 1)
		return strings.to_string(b)
	}
	parse_instances :: proc(n: int) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, LIMITS_HEAD + "seq:\n  - id: a\n    type: u1\ninstances:\n")
		for i in 0 ..< n - 1 do fmt.sbprintf(&b, "  p%d: {{pos: 'p%d * 0', type: u1}}\n", i, i + 1)
		fmt.sbprintf(&b, "  p%d: {{pos: 0, type: u1}}\n", n - 1)
		return strings.to_string(b)
	}
	Case :: struct {
		name: string,
		src:  string,
		ok:   bool,
	}
	cases := [?]Case {
		{"types", types(ksy.MAX_NESTING, false), true},
		{"types, one more", types(ksy.MAX_NESTING + 1, false), false},
		{"types, 100,000", types(100_000, false), false},
		{"sizeof", types(ksy.MAX_NESTING - 1, true), true},
		{"sizeof, one more", types(ksy.MAX_NESTING + 1, true), false},
		{"sizeof, 100,000", types(100_000, true), false},
		{"parse instances", parse_instances(ksy.MAX_NESTING), true},
		{"parse instances, one more", parse_instances(ksy.MAX_NESTING + 1), false},
		{"parse instances, 100,000", parse_instances(100_000), false},
	}
	for c in cases {
		kind, message := compile_kind(c.src)
		if c.ok {
			testing.expectf(t, kind == .None, "%s: %v %s", c.name, kind, message)
		} else {
			testing.expectf(t, kind == .Unsupported && strings.contains(message, "more than"), "%s: %v %s", c.name, kind, message)
		}
	}

	// value instances, each using the next: compiled from the first, which
	// nests, or from the last, which does not, as each field compiles one
	// more without evaluating it (false and ...)
	chain :: proc(links: int, in_order: bool) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, LIMITS_HEAD + "seq:\n  - id: n\n    type: u1\n")
		if in_order do for i in 0 ..< links do fmt.sbprintf(&b, "  - id: f%d\n    type: u1\n    if: 'false and i%d == 0'\n", i, i)
		fmt.sbprintf(&b, "  - id: c\n    type: u1\n    valid:\n      expr: 'i%d == 1'\ninstances:\n  i0: {{value: n}}\n", links - 1)
		for i in 1 ..< links do fmt.sbprintf(&b, "  i%d: {{value: 'i%d'}}\n", i, i - 1)
		return strings.to_string(b)
	}
	for in_order in ([]bool{false, true}) {
		// a field using i(k) uses a chain of k + 1
		kind, message := compile_kind(chain(expr.MAX_CHAIN, in_order))
		testing.expectf(t, kind == .None, "a chain of %v (in order %v): %v %s", expr.MAX_CHAIN, in_order, kind, message)
		kind, message = compile_kind(chain(expr.MAX_CHAIN + 1, in_order))
		testing.expectf(t, kind == .Unsupported && strings.contains(message, "chains of more than"), "a chain of %v (in order %v): %v %s", expr.MAX_CHAIN + 1, in_order, kind, message)
	}
	input := make([]byte, expr.MAX_CHAIN + 2, context.temp_allocator)
	input[0] = 1
	result, _ := decode_limited(t, chain(expr.MAX_CHAIN, true), input, {})
	testing.expect_value(t, result, "ok")
}
