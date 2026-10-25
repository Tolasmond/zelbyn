package tests

import "../zelbyn/cli"
import "../zelbyn/codegen"
import dmp "../zelbyn/dump"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// What generated code does is checked by tools/codegen_tests/check.py,
// which decodes every input these tests decode again, with the code
// generated from its plan (tests/helpers.odin, CODEGEN_RECORD); these
// tests check what the code declares.

// A schema whose ids are Odin keywords and whose types' names meet once
// made Ada_Case (a::b and a_b), with a type that Args would name, and a bit
// field whose -orig-id is no identifier, and which meets another's once
// made one.
@(private = "file")
NAMES_KSY :: `meta:
  id: names
  endian: le
seq:
  - id: type
    type: u1
  - id: map
    type: args
  - id: in
    type: a_b
  - id: proc
    type: a
  - id: flags
    type: u1
    -bits:
      - id: top
        -orig-id: Top Bits
        low: 4
        high: 7
      - id: top_bits
        low: 0
        high: 3
types:
  args:
    seq:
      - id: context
        type: u1
  a_b:
    seq:
      - id: x
        type: u1
  a:
    seq:
      - id: inner
        type: b
    types:
      b:
        seq:
          - id: y
            type: u1
`

@(private = "file")
generate_from :: proc(t: ^testing.T, src: string, options: codegen.Options, loc := #caller_location) -> (code: string, ok: bool) {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v at %v:%v: %s", err.kind, err.line, err.column, err.message, loc = loc) do return
	gen_err: codegen.Error
	code, gen_err = codegen.generate(&ff, options, context.temp_allocator)
	defer codegen.destroy_error(&gen_err)
	return code, testing.expectf(t, gen_err.message == "", "generate: %s", gen_err.message, loc = loc)
}

// Keywords take a _ after them, names that meet a number, and a name that
// is no identifier its characters that cannot be in one made _; the dump
// and the paths keep the schema's names.
@(test)
codegen_names :: proc(t: ^testing.T) {
	code, ok := generate_from(t, NAMES_KSY, {})
	if !ok do return
	for want in ([]string {
		"package names\n",
		"import dat \"zelbyn:data\"\n",
		"Names :: struct {",
		"\ttype: u8,",
		"\tmap_: ^Args_2,",
		"\tin_: ^A_B,",
		"\tproc_: ^A,",
		"Args_2 :: struct {",
		"\tcontext_: u8,",
		"A_B_2 :: struct {",
		"A :: struct {",
		"\tTop_Bits: u8, // (Top Bits)",
		"\ttop_bits: u8,",
		"dat.dump_path(path, n, \"Top Bits\", 0)",
	}) {
		testing.expectf(t, strings.contains(code, want), "the code has no %q", want)
	}
	// the dump the code writes, which check.py compares with this
	testing.expect_value(t, ksy_names_dump(t), "names[0].type[0] = 1\nnames[0].map[0].context[0] = 2\nnames[0].in[0].x[0] = 3\nnames[0].proc[0].inner[0].y[0] = 4\nnames[0].flags[0] = 165\nnames[0].top_bits[0] = 5\nnames[0].Top Bits[0] = 10\n")
}

@(private = "file")
ksy_names_dump :: proc(t: ^testing.T) -> string {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile(NAMES_KSY, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %s", err.message) do return ""
	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, {1, 2, 3, 4, 0xa5}, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v", d.err.kind) do return ""
	b := strings.builder_make(context.temp_allocator)
	werr := dmp.write_text(strings.to_writer(&b), &ff, &d.tree)
	testing.expectf(t, werr == .None, "dump: %v", werr)
	return strings.to_string(b)
}

// The package's name and the import path of package data are those given,
// and the code is the same each time it is generated.
@(test)
codegen_options :: proc(t: ^testing.T) {
	a, a_ok := generate_from(t, SAMPLE_KSY, {package_name = "decoder", runtime = "../vendor/data"})
	b, b_ok := generate_from(t, SAMPLE_KSY, {package_name = "decoder", runtime = "../vendor/data"})
	if !a_ok || !b_ok do return
	testing.expect(t, a == b, "the code differs from one generation to the next")
	testing.expect(t, strings.contains(a, "\npackage decoder\n"), "the package is not named decoder")
	testing.expect(t, strings.contains(a, "\nimport dat \"../vendor/data\"\n"), "data is not imported from ../vendor/data")
	testing.expect(t, strings.contains(a, "\nread :: proc(data: []byte, args := Args{}) -> (root: ^Sample, err: dat.Parse_Error) {\n"), "no read of Sample")
	testing.expect(t, strings.contains(a, "\nwrite_text :: proc(w: io.Writer, root: ^Sample) -> io.Error {\n"), "no write_text of Sample")
}

// The params of the top-level type are the members of Args, with the
// types of their arguments, a user type's as the bytes it is read from.
@(test)
codegen_args :: proc(t: ^testing.T) {
	code, ok := generate_from(t, `meta:
  id: p
params:
  - id: count
    type: u2
  - id: wide
    type: bool
  - id: magic
    type: bytes
  - id: label
    type: str
  - id: hdr
    type: hdr_t
seq:
  - id: x
    size: count
types:
  hdr_t:
    seq:
      - id: a
        type: u1
`, {})
	if !ok do return
	testing.expect(t, strings.contains(code, "Args :: struct {\n\tcount: i64,\n\twide: bool,\n\tmagic: []byte,\n\tlabel: string,\n\thdr: []byte,\n}"), "Args does not have the params' types")
	testing.expect(t, strings.contains(code, "\tcount: i128, // a param\n"), "an integer param is not an i128")
	testing.expect(t, strings.contains(code, "\thdr: ^Hdr_T, // a param\n"), "the param of a user type is not its instance")
}

// zelbyn gen writes the package, as <package>.odin in --out, which it
// makes; its usage errors exit 2, and a schema it cannot load 1.
@(test)
cli_gen :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "zelbyn_cli_gen_*", context.temp_allocator)
	if !testing.expectf(t, dir_err == nil, "making a temporary directory: %v", dir_err) do return
	defer os.remove_all(dir)
	schema, _ := filepath.join({dir, "sample.ksy"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(schema, SAMPLE_KSY) == nil, "writing the schema") do return
	bad, _ := filepath.join({dir, "bad.ksy"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(bad, "meta:\n  id: p\nseq:\n  - id: a\n    type: nope\n") == nil, "writing the schema") do return
	out, _ := filepath.join({dir, "out", "sample"}, context.temp_allocator)

	Case :: struct {
		name:      string,
		args:      []string,
		exit_code: int,
		stdout:    string, // must occur in stdout; "" when it must be empty
		stderr:    string, // as stdout
	}
	cases := []Case {
		{"help", {"gen", "--help"}, 0, "--out", ""},
		{"no --out", {"gen", schema}, 2, "", "Usage:"},
		{"no schema", {"gen", "--out", out}, 2, "", "Usage:"},
		{"a schema error", {"gen", bad, "--out", out}, 1, "", ":5:11: Invalid: a: unknown type nope"},
		{"generated", {"gen", schema, "--out", out}, 0, "", ""},
		{"named", {"gen", schema, "--out", out, "--package", "smp", "--runtime", "vendor:data"}, 0, "", ""},
	}
	for c in cases {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "zelbyn")
		append(&args, ..c.args)
		stdout := strings.builder_make(context.temp_allocator)
		stderr := strings.builder_make(context.temp_allocator)
		code := cli.execute(args[:], strings.to_writer(&stdout), strings.to_writer(&stderr))
		testing.expectf(t, code == c.exit_code, "%s: exit code %v, want %v; stderr: %s", c.name, code, c.exit_code, strings.to_string(stderr))
		for x in ([][2]string{{strings.to_string(stdout), c.stdout}, {strings.to_string(stderr), c.stderr}}) {
			if x[1] == "" {
				testing.expectf(t, x[0] == "", "%s: output not empty: %q", c.name, x[0])
			} else {
				testing.expectf(t, strings.contains(x[0], x[1]), "%s: output %q, want it to contain %q", c.name, x[0], x[1])
			}
		}
	}

	for f in ([][2]string{{"sample.odin", "\npackage sample\n"}, {"smp.odin", "\nimport dat \"vendor:data\"\n"}}) {
		path, _ := filepath.join({out, f[0]}, context.temp_allocator)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, err == nil, "reading %s: %v", path, err) do continue
		testing.expectf(t, strings.contains(string(data), f[1]), "%s has no %q", path, f[1])
	}
}
