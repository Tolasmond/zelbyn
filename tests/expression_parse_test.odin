package tests

import arn "../zelbyn/arena"
import expr "../zelbyn/expression"
import mdata "../zelbyn/metadata"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

// Each text parses to the fully parenthesized want.
@(private = "file")
PRECEDENCE_CASES := [?][2]string {
	{"1 + 2 * 3", "(1 + (2 * 3))"},
	{"1 * 2 + 3", "((1 * 2) + 3)"},
	{"1 - 2 - 3", "((1 - 2) - 3)"},
	{"a / b % c", "((a / b) % c)"},
	{"a << 1 + 2", "(a << (1 + 2))"},
	{"a & b << 1", "(a & (b << 1))"},
	{"a | b ^ c & d", "(a | (b ^ (c & d)))"},
	{"a & 1 == 0", "((a & 1) == 0)"},
	{"a | b < c", "((a | b) < c)"},
	{"not a == b", "(not (a == b))"},
	{"not a and b or c and d", "(((not a) and b) or (c and d))"},
	{"a and not not b", "(a and (not (not b)))"},
	{"a ? b : c ? d : e", "(a ? b : (c ? d : e))"},
	{"a ? b ? c : d : e", "(a ? (b ? c : d) : e)"},
	{"a or b ? c + 1 : d", "((a or b) ? (c + 1) : d)"},
	{"-a.b.c * 2", "((-a.b.c) * 2)"},
	{"~-1", "(~(-1))"},
	{"- 2 << 1", "((-2) << 1)"},
	{"+1", "1"},
	{"( ( a ) )", "a"},
	{"a?b:c", "(a ? b : c)"},
	{"_io.pos + _root.hdr._parent", "(_io.pos + _root.hdr._parent)"},
	{"block_type::end_of_file", "block_type::end_of_file"},
	{"0x1F + 0B1_0 + 0o17 + 1_000 + 0", "((((31 + 2) + 15) + 1000) + 0)"},
	{"9223372036854775807", "9223372036854775807"},
	{"true != false", "(true != false)"},
	{`'a\n' + "b\t\"\\\101\u00e9"`, `("a\\n" + "b\011\"\\A\303\251")`},
	{"a[1][b + 2].c", "a[1][(b + 2)].c"},
	{"x.length + y.to_s.to_i", "(x.length + y.to_s.to_i)"},
	{"sizeof<t> + bitsizeof < a :: b > * a._sizeof", "(sizeof<t> + (bitsizeof<a::b> * a._sizeof))"},
	{"a.b.as<u4> + c[0].as < x :: y >.d", "(a.b.as<u4> + c[0].as<x::y>.d)"},
	{"[a, [1, 2,], ][0]", "[a, [1, 2]][0]"},
	{"a.first + a.last.b + a.min - a.max", "(((a.first + a.last.b) + a.min) - a.max)"},
	{"1.to_s", "1.to_s"},
}

@(test)
expression_precedence :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)

	for c in PRECEDENCE_CASES {
		e, err := expr.parse(c[0], virtual.arena_allocator(&arena))
		defer expr.destroy_error(&err)
		if !testing.expectf(t, err.kind == .None, "%q: %v at %v: %s", c[0], err.kind, err.offset, err.message) do continue
		testing.expectf(t, expr.to_string(e, context.temp_allocator) == c[1], "%q parses as %s, want %s", c[0], expr.to_string(e, context.temp_allocator), c[1])
	}
}

@(private = "file")
Compile_Error_Case :: struct {
	text:    string,
	kind:    expr.Error_Kind,
	offset:  int,
	message: string, // must occur in the error's message
}

// Compiled as an Int in the scope of r (Expr_Plan), or of hdr where noted.
@(private = "file")
COMPILE_ERROR_CASES := [?]Compile_Error_Case {
	// syntax
	{"", .Syntax, 0, "unexpected end of expression"},
	{"a +", .Syntax, 3, "unexpected end of expression"},
	{"(a + 1", .Syntax, 6, "expected ), found end of expression"},
	{"a 1", .Syntax, 2, "unexpected 1"},
	{"a $ 1", .Syntax, 2, "unexpected character '$'"},
	{"a < b < 3", .Syntax, 6, "comparisons cannot be chained"},
	{"a == b != c", .Syntax, 7, "comparisons cannot be chained"},
	{"1 + not a", .Syntax, 4, "not must be parenthesized"},
	{"a ? 1", .Syntax, 5, "expected : in ?:"},
	{"a.", .Syntax, 2, "expected a name after ."},
	{"and", .Syntax, 0, "unexpected and"},
	{"x::", .Syntax, 3, "expected an enum value after ::"},
	{"08", .Syntax, 0, "use 0o for octal"},
	{"0x", .Syntax, 0, "invalid integer literal 0x"},
	{"0b12", .Syntax, 0, "invalid integer literal 0b12"},
	{"1__0", .Syntax, 0, "invalid integer literal 1__0"},
	{"18446744073709551616x", .Syntax, 0, "invalid integer literal 18446744073709551616x"},
	{"0x10000000000000000g", .Syntax, 0, "invalid integer literal 0x10000000000000000g"},
	{"1_", .Syntax, 0, "invalid integer literal 1_"},
	{"1e5", .Invalid, 0, "expected an integer, found a float"},
	{"18446744073709551616", .Unsupported, 0, "is above 2^64 - 1"},
	{`"abc`, .Syntax, 0, "unterminated string literal"},
	{`'abc`, .Syntax, 0, "unterminated string literal"},
	{`"a\q"`, .Syntax, 2, "unknown escape \\q"},
	{`"\400"`, .Syntax, 1, "above \\377"},
	{`"\u12"`, .Syntax, 1, "four hex digits"},
	{"a[1", .Syntax, 3, "expected ], found end of expression"},
	{"sizeof<1>", .Syntax, 7, "expected a type name in sizeof<>, found 1"},
	{"bitsizeof<a b", .Syntax, 12, "expected > after the type name, found b"},

	// outside the subset
	{"2.", .Invalid, 0, "expected an integer, found a float"},
	{"1.5x", .Syntax, 0, "invalid float literal 1.5x"},
	{"1 + 1e999", .Unsupported, 4, "float literal 1e999 does not fit in a 64-bit float"},
	{"1e", .Syntax, 0, "invalid integer literal 1e"},
	{"1.5 % 2", .Unsupported, 4, "% of a float is not supported"},
	{"1.5 | 1", .Invalid, 0, "expected an integer, found a float"},
	{"1.5 + 'a'", .Invalid, 6, "expected a number, found a string"},
	{"-1.5", .Invalid, 0, "expected an integer, found a float"},
	{"[]", .Invalid, 0, "an array literal cannot be empty"},
	{"[1, true]", .Invalid, 4, "the items of an array literal must have one type: an integer, not a boolean"},
	// a float among the items makes the first one a float too, or an error
	{"[true, 1.5][0].to_i", .Invalid, 1, "the items of an array literal must have one type: a float, not a boolean"},
	{"[1.5, true][0].to_i", .Invalid, 6, "the items of an array literal must have one type: a float, not a boolean"},
	{"['a', 1.5][0].to_i", .Invalid, 1, "the items of an array literal must have one type: a float, not a string"},
	{"[1.5, 'a'][0].to_i", .Invalid, 6, "the items of an array literal must have one type: a float, not a string"},
	{"[hdr.tag, 1.5][0].to_i", .Invalid, 5,"the items of an array literal must have one type: a float, not a byte array"},
	{"[[256], 1.5][0].to_i", .Invalid, 1, "the items of an array literal must have one type: a float, not an array"},
	{"[1.5, [256]][0].to_i", .Invalid, 6, "the items of an array literal must have one type: a float, not an array"},
	{"[a, 1.5, true][0].to_i", .Invalid, 9, "the items of an array literal must have one type: a float, not a boolean"},
	{"[1 2]", .Syntax, 3, "expected , or ] in an array literal, found 2"},
	{"a.to_s()", .Unsupported, 2, "an integer has no method to_s(...)"},
	{"to_s(1)", .Syntax, 4, "only a method, .name(...), can be called"},
	{"'x'.substring(1, 2", .Syntax, 18, "expected , or ), found end of expression"},
	{"'x'.substring(1).length", .Invalid, 4, ".substring takes 2 arguments, not 1"},
	{"'x'.substring('a', 1).length", .Invalid, 14, "expected an integer, found a string"},
	{"hdr.tag.to_s('ASCII').length", .Invalid, 8, "encodings cannot be used here"},
	{"hdr.tag.to_s(1).length", .Unsupported, 13, "the encoding of .to_s must be a string literal"},
	{"[1.5].as<bytes>.size", .Invalid, 6, "an array of a float cannot be cast to bytes"},
	{"a.as<bytes>.size", .Invalid, 2, "an integer cannot be cast to bytes"},
	{"a.as<1>", .Syntax, 5, "expected a type name in .as<>, found 1"},
	{"a::b::c", .Invalid, 0, "no enum a::b"},
	{"[[1.5], ['a']][0][0]", .Invalid, 8, "the items of an array literal must have one type: an array of a float, not of a string"},
	{"a::b::", .Syntax, 6, "expected an enum value after ::, found end of expression"},
	{"_io", .Invalid, 0, "expected an integer, found a stream"},
	{"_root._io.foo", .Unsupported, 10, "foo of a stream is not supported; only .pos, .size and .eof are"},
	{"(a == 1 ? _io : 2).size", .Invalid, 16, "expected a stream, found an integer"},
	{"a._io", .Invalid, 2, "an integer has no _io"},
	{"true ? _io : 1", .Invalid, 13, "expected a stream, found an integer"},
	{"_io == _io ? 1 : 0", .Unsupported, 4, "comparing a stream"},
	{"_io.foo", .Unsupported, 4, "foo of a stream is not supported"},
	{"_", .Invalid, 0, "_ is only defined in repeat-until"},
	{"hdr.n.size", .Unsupported, 6, "an integer has no member size"},
	{"items.v", .Unsupported, 6, "an array has no member v"},
	{"hdr._parent.a", .Unsupported, 4, "._parent is only supported after _parent"},
	{"hdr._root", .Unsupported, 4, "._root is not supported"},
	{"hdr == hdr ? 1 : 0", .Unsupported, 4, "comparing a set"},

	// names and types
	{"nope", .Invalid, 0, "r has no field nope"},
	{"hdr.nope + 1", .Invalid, 4, "hdr has no field nope"},
	{"_parent.a", .Invalid, 0, "_parent: r has no enclosing set"},
	{"_index", .Invalid, 0, "_index is only defined for a repeated field"},
	{"a == 1", .Invalid, 2, "expected an integer, found a boolean"},
	{"a and true ? 1 : 0", .Invalid, 0, "expected a boolean, found an integer"},
	{"a ? 1 : 0", .Invalid, 0, "expected a boolean, found an integer"},
	{"true ? 1 : false", .Invalid, 11, "expected an integer, found a boolean"},
	{"1 == true ? 1 : 0", .Invalid, 5, "expected an integer, found a boolean"},
	{"-true", .Invalid, 1, "expected an integer, found a boolean"},
	{"hdr", .Invalid, 0, "expected an integer, found a set"},
	{"items", .Invalid, 0, "expected an integer, found an array"},
	{"hdr.tag", .Invalid, 4, "expected an integer, found a byte array"},
	{"block_type::end_of_file", .Invalid, 0, "no enum block_type"},
	{"'ABC'", .Invalid, 0, "expected an integer, found a string"},
	{"items[0]", .Invalid, 5, "expected an integer, found a set"},
	{"a[0]", .Invalid, 1, "an integer cannot be indexed"},
	{"items['x'].v", .Invalid, 6, "expected an integer, found a string"},
	{"('a' + 1).length", .Invalid, 7, "expected a string, found an integer"},
	{"1 + 'a'", .Invalid, 4, "expected an integer, found a string"},
	{"'a' < 1 ? 1 : 0", .Invalid, 6, "expected a string, found an integer"},
	{"'a'.size", .Unsupported, 4, "a string has no member size"},
	{"a.length", .Unsupported, 2, "an integer has no member length"},
	{"items.min", .Unsupported, 6, ".min of an array is only supported when its values are integers, not a set"},
	{"_io.size.to_i + 'a'.to_i + hdr.tag.to_i", .Unsupported, 35, "a byte array has no member to_i"},
	{"_sizeof", .Invalid, 0, "sizes cannot be used here"},
	{"a._sizeof", .Invalid, 2, "sizes cannot be used here"},
	{"sizeof<u1>", .Invalid, 0, "sizes cannot be used here"},
	{"items[0]._sizeof", .Unsupported, 9, "_sizeof is only supported of an attribute"},
}

@(test)
expression_compile_errors :: proc(t: ^testing.T) {
	p: Expr_Plan
	defer mdata.destroy_file_format(&p.ff)
	make_expr_plan(t, &p)

	for c in COMPILE_ERROR_CASES {
		e, err := expr.compile(c.text, {types = {p.root}}, .Int, arn.arena_allocator(&p.ff.arena))
		defer expr.destroy_error(&err)
		testing.expectf(
			t,
			e == nil && err.kind == c.kind && err.offset == c.offset && strings.contains(err.message, c.message),
			"%q: got %v at %v, %q; want %v at %v, a message containing %q",
			c.text, err.kind, err.offset, err.message, c.kind, c.offset, c.message,
		)
	}
}

// _parent resolves against the enclosing set given in the scope.
@(test)
expression_parent_scope :: proc(t: ^testing.T) {
	p: Expr_Plan
	defer mdata.destroy_file_format(&p.ff)
	make_expr_plan(t, &p)
	a := arn.arena_allocator(&p.ff.arena)

	e, err := expr.compile("_parent._parent.a", {types = {p.root, p.hdr}}, .Int, a)
	defer expr.destroy_error(&err)
	testing.expectf(t, e == nil && err.kind == .Invalid && strings.contains(err.message, "_parent: r has no enclosing set"), "%v: %s", err.kind, err.message)

	e2, err2 := expr.compile("_parent.hdr.n + n", {types = {p.root, p.hdr}}, .Int, a)
	defer expr.destroy_error(&err2)
	testing.expectf(t, e2 != nil && err2.kind == .None, "%v: %s", err2.kind, err2.message)
}
