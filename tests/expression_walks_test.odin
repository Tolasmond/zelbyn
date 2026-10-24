package tests

import "base:runtime"
import expr "../zelbyn/expression"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdat "../zelbyn/metadata"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

// The procedures that switch on an expression's variant, each listed in
// doc/arch.md ("Walks over expressions"), with whether it handles every
// variant (an exhaustive switch, which fails to compile when a variant is
// added and it does not handle it) or some (#partial, by the type of the
// expressions it follows or the pattern it looks for).
@(private = "file")
Walk :: struct {
	file, procedure: string,
	exhaustive:      bool,
}

@(private = "file")
WALKS := [?]Walk {
	{"zelbyn/expression/print.odin", "write", true},
	{"zelbyn/expression/resolve.odin", "resolve", true},
	{"zelbyn/expression/resolve.odin", "reach_of", true},
	{"zelbyn/ksy/types.odin", "note_escapes", true},
	{"zelbyn/reader/eval.odin", "eval", true},
	// expressions of type Struct
	{"zelbyn/expression/resolve.odin", "depth", false},
	{"zelbyn/expression/resolve.odin", "struct_node", false},
	{"zelbyn/expression/resolve.odin", "through_param", false},
	{"zelbyn/expression/resolve.odin", "through_indirect", false},
	{"zelbyn/reader/eval.odin", "enclosing", false},
	// expressions of type Stream
	{"zelbyn/expression/resolve.odin", "keep_streams", false},
	{"zelbyn/reader/eval.odin", "eval_stream", false},
	{"zelbyn/reader/eval.odin", "stream_reader", false},
	// expressions of type Array
	{"zelbyn/expression/resolve.odin", "array_item_type", false},
	{"zelbyn/expression/resolve.odin", "first_item", false},
	{"zelbyn/reader/eval.odin", "eval_kept", false},
	// patterns
	{"zelbyn/expression/resolve.odin", "direct_form", false},
	{"zelbyn/expression/resolve.odin", "direct_field", false},
	{"zelbyn/expression/resolve.odin", "constant_wide", false},
	{"zelbyn/expression/resolve.odin", "is_constant", false},
	{"zelbyn/expression/resolve.odin", "resolve_member_size_of", false},
	{"zelbyn/expression/resolve.odin", "resolve_cast", false},
	{"zelbyn/ksy/constants.odin", "int_literal", false},
}

// Every switch on an expression's variant in zelbyn/ is one of WALKS,
// exhaustive or not as WALKS says, every one of WALKS is in the source and
// in doc/arch.md's inventory, so that a walk added, or one whose switch
// becomes #partial, is seen.
@(test)
expression_walks_inventory :: proc(t: ^testing.T) {
	Found :: struct {
		walk:    Walk,
		partial: bool,
	}
	found := make([dynamic]Found, context.temp_allocator)
	dirs, err := os.read_all_directory_by_path("zelbyn", context.temp_allocator)
	if !testing.expectf(t, err == nil, "reading zelbyn/: %v", err) do return
	for dir in dirs {
		if dir.type != .Directory do continue
		files, files_err := os.read_all_directory_by_path(fmt.tprintf("zelbyn/%s", dir.name), context.temp_allocator)
		if !testing.expectf(t, files_err == nil, "reading zelbyn/%s: %v", dir.name, files_err) do return
		for f in files {
			if !strings.has_suffix(f.name, ".odin") do continue
			path := fmt.tprintf("zelbyn/%s/%s", dir.name, f.name)
			data, read_err := os.read_entire_file(path, context.temp_allocator)
			if !testing.expectf(t, read_err == nil, "reading %s: %v", path, read_err) do return
			procedure := ""
			for line in strings.split_lines(string(data), context.temp_allocator) {
				// a top-level procedure: name :: proc or name :: #force_inline proc
				if colon := strings.index(line, " :: "); colon > 0 && !strings.has_prefix(line, "\t") {
					rest := line[colon + 4:]
					if strings.has_prefix(rest, "proc") || strings.has_prefix(rest, "#force_inline proc") do procedure = line[:colon]
				}
				trimmed := strings.trim_left_space(line)
				is_switch := strings.has_prefix(trimmed, "switch ") || strings.has_prefix(trimmed, "#partial switch ")
				if !is_switch || !strings.contains(trimmed, ".variant {") do continue
				w := Walk{path, procedure, false}
				partial := strings.has_prefix(trimmed, "#partial")
				k := -1
				for x, j in found do if x.walk.file == path && x.walk.procedure == procedure do k = j
				if k < 0 do append(&found, Found{w, partial})
				else do found[k].partial ||= partial
			}
		}
	}

	arch, arch_err := os.read_entire_file("doc/arch.md", context.temp_allocator)
	if !testing.expectf(t, arch_err == nil, "reading doc/arch.md: %v", arch_err) do return
	for f in found {
		k := -1
		for w, j in WALKS do if w.file == f.walk.file && w.procedure == f.walk.procedure do k = j
		if !testing.expectf(t, k >= 0, "%s: %s switches on an expression's variant, but is not in WALKS or doc/arch.md's inventory", f.walk.file, f.walk.procedure) do continue
		w := WALKS[k]
		testing.expectf(t, w.exhaustive == !f.partial, "%s: %s is %s, but WALKS says %s", w.file, w.procedure, f.partial ? "#partial" : "exhaustive", w.exhaustive ? "exhaustive" : "#partial")
	}
	for w in WALKS {
		in_source := false
		for f in found do in_source ||= f.walk.file == w.file && f.walk.procedure == w.procedure
		testing.expectf(t, in_source, "%s: %s is in WALKS, but switches on no expression's variant", w.file, w.procedure)
		testing.expectf(t, strings.contains(string(arch), fmt.tprintf("`%s`", w.procedure)), "%s is not in doc/arch.md's inventory", w.procedure)
	}
}

// The checks of the schema that walks every variant (WALKED_SCHEMA): each
// is the valid of a byte, true on WALKED_INPUT. Each variant is in one, and
// every variant an expression of type Struct can be is the base of a value
// instance that uses _parent (up: depth, struct_node, enclosing), of one
// that does not (twice), and an argument through a param (holder's via:
// through_param); the variants of type Stream are the stream of .size and
// .pos, and those of type Array are indexed and sized, also as a value
// instance (kept: eval_kept).
@(private = "file")
WALKED_CHECKS := [?]string {
	// literals and operators
	"1 + 1 == 2",
	"18446744073709551615 > 0",
	"1.5 > 1",
	"true",
	"'ab' == \"ab\"",
	"-n == -1 and ~0 == -1 and not false",
	// fields, sizes, methods and casts
	"n == 1",
	"items.size == 2",
	"s.length == 3",
	"n.to_s == '1'",
	"'12'.to_i == 12",
	"items.last.v == 3",
	"raw == [0x61, 0x62]",
	"raw.to_s('ASCII') == 'ab'",
	"s.substring(0, 2) == 'ab'",
	"[n + 96, 98].as<bytes> == raw",
	"[1, 300][1] == 300",
	"[1, 300].size == 2",
	"k == 7",
	"e::a.to_i == 1",
	"sizeof<item> == 1",
	"one._sizeof == 1",
	"n.as<u2> == 1",
	// streams
	"_io.pos > 0",
	"_io.size > 0",
	"not _io.eof",
	"one._io.size == 1",
	"(n == 1 ? one._io : _io).size == 1",
	// each variant of type Struct as the base of a value instance
	"one.up == 5",
	"items[1].up == 4",
	"items.first.up == 3",
	"sw.as<item>.up == 6",
	"pick.up == 3",
	"_root.rv == 2",
	"(n == 1 ? one : items[0]).twice == 8",
	"until[0].up == 7",
	// arrays
	"(n == 1 ? idx : idx).size == 2",
	"[[1, 300], [2, 400]][1][0] == 2",
	"[[1, 300], [2, 400]].first.size == 2",
	"kept.size == 2",
	"kept[1].v == 3",
	// each variant of type Struct through a param
	"h_field.via == 8",
	"h_index.via == 6",
	"h_method.via == 4",
	"h_cast.via == 10",
	"h_value.via == 4",
	"h_ternary.via == 8",
}

@(private = "file")
WALKED_SCHEMA :: `meta:
  id: w
  endian: le
  encoding: ASCII
params:
  - id: k
    type: u1
seq:
  - id: n
    type: u1
  - id: items
    type: item
    repeat: expr
    repeat-expr: 2
  - id: one
    type: item
    size: 1
  - id: sw
    type:
      switch-on: n
      cases:
        1: item
  - id: s
    type: str
    size: 3
  - id: raw
    size: 2
  - id: until
    type: item
    repeat: until
    repeat-until: _.up > 0
  - id: idx
    type: u1
    repeat: expr
    repeat-expr: 2
    valid:
      expr: _index >= 0
  - id: h_field
    type: holder(one)
  - id: h_index
    type: holder(items[1])
  - id: h_method
    type: holder(items.first)
  - id: h_cast
    type: holder(sw.as<item>)
  - id: h_value
    type: holder(pick)
  - id: h_ternary
    type: 'holder(n == 1 ? one : items[0])'
%sinstances:
  pick:
    value: items[0]
  rv:
    value: n * 2
  kept:
    value: items
enums:
  e:
    1: a
types:
  item:
    seq:
      - id: v
        type: u1
    instances:
      up:
        value: _parent.n + v
      twice:
        value: v * 2
  holder:
    params:
      - id: p
        type: item
    instances:
      via:
        value: p.twice
`

// n, items, one, sw, s, raw, until and idx, then a byte for each check.
@(private = "file")
WALKED_INPUT :: "\x01\x02\x03\x04\x05abcab\x06\x00\x00"

// Records in seen the variant of e and of every expression in it. The
// switch is exhaustive, so a variant added fails to compile here until it
// is walked, and so until this test names it.
@(private = "file")
walk_expr :: proc(e: ^mdat.Expr, seen: ^map[string]bool) {
	if e == nil do return
	seen[fmt.tprintf("%v", reflect.union_variant_typeid(e.variant))] = true
	switch x in e.variant {
	case mdat.Int_Literal, mdat.Big_Literal, mdat.Float_Literal, mdat.Bool_Literal, mdat.String_Literal, mdat.Bytes_Literal:
	case mdat.Name, mdat.Enum_Constant, mdat.Size_Of, mdat.Repeat_Index, mdat.Repeat_Element, mdat.Root_Arg:
	case mdat.Instance:
	case mdat.Unary:
		walk_expr(x.operand, seen)
	case mdat.Binary:
		walk_expr(x.left, seen)
		walk_expr(x.right, seen)
	case mdat.Ternary:
		walk_expr(x.cond, seen)
		walk_expr(x.then, seen)
		walk_expr(x.otherwise, seen)
	case mdat.Index:
		walk_expr(x.operand, seen)
		walk_expr(x.index, seen)
	case mdat.Array_Literal:
		for item in x.items do walk_expr(item, seen)
	case mdat.Member:
		walk_expr(x.operand, seen)
	case mdat.Cast:
		walk_expr(x.operand, seen)
	case mdat.Call:
		walk_expr(x.operand, seen)
		for a in x.args do walk_expr(a, seen)
	case mdat.Field_Ref:
		walk_expr(x.base, seen)
	case mdat.Size:
		walk_expr(x.operand, seen)
	case mdat.String_Length:
		walk_expr(x.operand, seen)
	case mdat.To_S:
		walk_expr(x.operand, seen)
	case mdat.To_I:
		walk_expr(x.operand, seen)
	case mdat.Array_Method:
		walk_expr(x.operand, seen)
	case mdat.Io:
		walk_expr(x.instance, seen)
	case mdat.Io_Pos:
		walk_expr(x.stream, seen)
	case mdat.Io_Size:
		walk_expr(x.stream, seen)
	case mdat.Io_Eof:
		walk_expr(x.stream, seen)
	case mdat.Value_Ref:
		walk_expr(x.base, seen)
	case mdat.Switch_Cast:
		walk_expr(x.operand, seen)
	case mdat.Decode:
		walk_expr(x.operand, seen)
	case mdat.Substring:
		walk_expr(x.operand, seen)
		walk_expr(x.from, seen)
		walk_expr(x.to, seen)
	case mdat.To_Bytes:
		walk_expr(x.operand, seen)
	}
}

// Records the variants of every expression of the plan from node, each of
// which is also printed.
@(private = "file")
walk_plan :: proc(t: ^testing.T, node: ^mdat.Node, seen: ^map[string]bool, visited: ^map[^mdat.Node]bool) {
	if node == nil || node in visited do return
	visited[node] = true
	walk_variants :: proc(e: ^mdat.Expr, seen: ^map[string]bool) {
		if e == nil do return
		walk_expr(e, seen)
		_ = expr.to_string(e, context.temp_allocator)
	}
	walk_variants(node.cond, seen)
	#partial switch c in node.count {
	case mdat.Rule_Count:
		walk_variants(c.expr, seen)
	case mdat.Until_Count:
		walk_variants(c.expr, seen)
	}
	if l, ok := node.length.(mdat.Rule_Length); ok do walk_variants(l.expr, seen)
	walk_variants(node.pos, seen)
	walk_variants(node.io, seen)
	for a in node.args do walk_variants(a, seen)
	if v, ok := node.valid.(mdat.Valid_Expr); ok do for c in v.checks do walk_variants(c.cond, seen)
	for inst in node.instances {
		walk_variants(inst.cond, seen)
		walk_variants(inst.expr, seen)
	}
	for child in node.children do walk_plan(t, child, seen, visited)
	for p in node.parse_instances do walk_plan(t, p, seen, visited)
	if sw := node.switch_on; sw != nil {
		walk_variants(sw.on, seen)
		for c in sw.cases do walk_plan(t, c.node, seen, visited)
		walk_plan(t, sw.default, seen, visited)
	}
}

// Every variant of an expression is walked: each is in WALKED_SCHEMA,
// which compiles, as the resolver, note_escapes and reach_of walk it, and
// decodes with every check true, as the evaluator and the type-directed
// walks do; and each is printed (expression.to_string). The syntax
// variants are in the parsed checks, the others in the compiled plan, and
// Expr_Variant's own list of variants says which there are, so that one
// added fails here until a check uses it.
@(test)
expression_variants_walked :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for c, i in WALKED_CHECKS {
		quoted, _ := strings.replace_all(c, "'", "''", context.temp_allocator)
		fmt.sbprintf(&b, "  - id: c%v\n    type: u1\n    valid:\n      expr: '%s'\n", i, quoted)
	}
	src := fmt.tprintf(WALKED_SCHEMA, strings.to_string(b))

	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return

	input := make([dynamic]byte, context.temp_allocator)
	append(&input, WALKED_INPUT)
	for _ in WALKED_CHECKS do append(&input, 0)
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, input[:], &d, args = []fld.Value{i64(7)})
	failed := d.err.kind == .None ? "" : d.err.path
	testing.expectf(t, d.err.kind == .None, "%v at %v in %s", d.err.kind, d.err.offset, failed)

	seen := make(map[string]bool, context.temp_allocator)
	visited := make(map[^mdat.Node]bool, context.temp_allocator)
	walk_plan(t, ff.root, &seen, &visited)
	for c in WALKED_CHECKS {
		parsed, parse_err := expr.parse(c, context.temp_allocator)
		if !testing.expectf(t, parse_err.kind == .None, "%q: %v", c, parse_err.kind) {
			expr.destroy_error(&parse_err)
			continue
		}
		walk_expr(parsed, &seen)
		testing.expectf(t, expr.to_string(parsed, context.temp_allocator) != "", "%q: not printed", c)
	}
	union_info := runtime.type_info_base(type_info_of(mdat.Expr_Variant)).variant.(runtime.Type_Info_Union)
	for v in union_info.variants {
		name := fmt.tprintf("%v", v.id)
		testing.expectf(t, seen[name], "variant %s is in no check of WALKED_CHECKS, so no walk is tested on it", name)
	}
}
