package tests

import "../zelbyn/cli"
import "core:io"
import "core:os"
import "core:strings"
import "core:testing"

// A schema whose top-level type has a param of each kind --param gives: an
// integer, a boolean, bytes, a string and a user type, read from its bytes.
// Each is checked against the input, so that a wrong argument fails the
// decode.
@(private = "file")
PARAMS_SCHEMA :: `meta:
  id: p
  endian: le
  encoding: ASCII
params:
  - id: count
    type: u1
  - id: wide
    type: bool
  - id: magic
    type: bytes
  - id: label
    type: str
  - id: hdr
    type: hdr_t
seq:
  - id: values
    type: u1
    repeat: expr
    repeat-expr: count
  - id: extra
    type: u1
    if: wide
  - id: tag
    size: magic.size
    valid:
      expr: _ == magic
  - id: name
    type: str
    size: label.length
    valid:
      expr: _ == label
  - id: b
    type: u1
    valid:
      expr: _ == hdr.a
types:
  hdr_t:
    seq:
      - id: a
        type: u1
`

// The input that the cases' params describe: count=2, wide=true,
// magic=cafe, label=hi and hdr=07.
@(private = "file")
PARAMS_INPUT :: "\x01\x02\x03\xca\xfehi\x07"

// What a run of the command line wrote, and its exit code.
@(private = "file")
Run :: struct {
	exit_code:      int,
	stdout, stderr: string,
}

// Runs the command line args, the program's name first, with stdout and
// stderr in context.temp_allocator, or with stdout a writer that fails.
@(private = "file")
run_cli :: proc(args: []string, failing_stdout := false) -> Run {
	out := strings.builder_make(context.temp_allocator)
	err := strings.builder_make(context.temp_allocator)
	stdout := failing_stdout ? io.Writer{procedure = failing_write} : strings.to_writer(&out)
	code := cli.execute(args, stdout, strings.to_writer(&err))
	return {code, strings.to_string(out), strings.to_string(err)}
}

// A stream whose every write fails, as a full disk's or a closed pipe's.
@(private = "file")
failing_write :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	#partial switch mode {
	case .Write:
		return 0, .Short_Write
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Empty
}

// Writes data to a new temporary file named as pattern, whose path it
// returns, in context.temp_allocator; "" when it cannot.
@(private = "file")
temp_file :: proc(t: ^testing.T, pattern: string, data: string) -> string {
	f, err := os.create_temp_file("", pattern)
	if !testing.expectf(t, err == nil, "creating a temporary file: %v", err) do return ""
	path := strings.clone(os.name(f), context.temp_allocator)
	_, write_err := os.write(f, transmute([]byte)data)
	os.close(f)
	if !testing.expectf(t, write_err == nil, "writing %s: %v", path, write_err) do return ""
	return path
}

@(private = "file")
Cli_Case :: struct {
	name:           string,
	args:           []string, // after the program's name, with SCHEMA, BAD, INPUT and NONE for the files
	exit_code:      int,
	stdout:         string, // must occur in stdout; "" when stdout must be empty
	stderr:         string, // must occur in stderr; "" when stderr must be empty
	failing_stdout: bool,
}

// The command line: --help, the usage errors, among them --offsets with
// --dump json, --param in both forms and each of its errors, and the
// errors of loading, decoding and writing, each with its exit code, and
// with stdout empty whenever the run fails.
@(test)
cli_command_line :: proc(t: ^testing.T) {
	schema := temp_file(t, "zelbyn_cli_*.ksy", PARAMS_SCHEMA)
	input := temp_file(t, "zelbyn_cli_*.bin", PARAMS_INPUT)
	bad_schema := temp_file(t, "zelbyn_cli_*.ksy", "meta:\n  id: p\nseq:\n  - id: a\n    type: nope\n")
	defer {
		for path in ([]string{schema, input, bad_schema}) do if path != "" do os.remove(path)
	}
	if schema == "" || input == "" || bad_schema == "" do return

	cases := []Cli_Case {
		{"help", {"--help"}, 0, "--param <string>, multiple", "", false},
		{"no arguments", {}, 2, "", "Usage:", false},
		{"an unknown flag", {"SCHEMA", "INPUT", "--bogus"}, 2, "", "Usage:", false},
		{"a bad --dump", {"SCHEMA", "INPUT", "--dump", "xml"}, 2, "", `error: --dump must be tree or json, not "xml"`, false},
		{"--offsets with --dump json", {"SCHEMA", "INPUT", "--offsets", "--dump", "json"}, 2, "", "error: --offsets applies only to --dump tree", false},
		{"--param without a value", {"SCHEMA", "INPUT", "--param"}, 2, "", "error: --param needs name=value", false},
		{"params, as a tree", {"SCHEMA", "INPUT", "--param", "count=2", "--param=wide=true", "--param", "label=hi", "--param", "magic=CAfe", "--param", "hdr=07"}, 0, "p[0].values[0] = 1\np[0].values[1] = 2\np[0].extra[0] = 3\np[0].tag[0] = <2 bytes> ca fe\np[0].name[0] = \"hi\"\np[0].b[0] = 7\n", "", false},
		{"params, with offsets", {"SCHEMA", "INPUT", "--offsets", "--param", "count=0x2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 0, "p[0].name[0] = \"hi\" @0x5\np[0].b[0] = 7 @0x7\n", "", false},
		{"params, as JSON", {"SCHEMA", "INPUT", "--dump", "json", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 0, `{"p":[{"values":[1,2],"extra":[3],"tag":["cafe"],"name":["hi"],"b":[7]}]}`, "", false},
		{"a param missing", {"SCHEMA", "INPUT", "--param", "count=2", "--param", "wide=true", "--param", "magic=cafe", "--param", "hdr=07"}, 2, "", "error: the schema's top-level type needs --param label=value", false},
		{"an unknown param", {"SCHEMA", "INPUT", "--param", "nope=1"}, 2, "", "error: --param nope=1: the schema's top-level type has no param nope", false},
		{"a param twice", {"SCHEMA", "INPUT", "--param", "count=2", "--param", "count=3"}, 2, "", "error: --param count=3: param count is given twice", false},
		{"not name=value", {"SCHEMA", "INPUT", "--param", "count"}, 2, "", "error: --param count is not name=value", false},
		{"not an integer", {"SCHEMA", "INPUT", "--param", "count=two"}, 2, "", `count is an integer, not "two"`, false},
		{"not a boolean", {"SCHEMA", "INPUT", "--param=wide=yes"}, 2, "", `wide is true or false, not "yes"`, false},
		{"bytes not in hex", {"SCHEMA", "INPUT", "--param", "magic=caf"}, 2, "", `magic is bytes, in hex (0a1b), not "caf"`, false},
		{"a user type not in hex", {"SCHEMA", "INPUT", "--param", "hdr=zz"}, 2, "", `hdr is bytes, in hex (0a1b), not "zz"`, false},
		{"an argument the input fails", {"SCHEMA", "INPUT", "--param", "count=2", "--param", "wide=true", "--param", "label=ho", "--param", "magic=cafe", "--param", "hdr=07"}, 1, "", "error: Expr_False at 0x00000005 in p[0].name[0]", false},
		// the argument of hdr, a user type, is read first: its instance and
		// its field, two steps; then the root, values, extra, tag, name and b
		{"--max-steps reached", {"SCHEMA", "INPUT", "--max-steps=3", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 1, "", "error: Step_Limit at 0x00000000 in p[0].values[0]", false},
		{"--max-steps and --max-memory within", {"SCHEMA", "INPUT", "--max-steps", "9", "--max-memory=1M", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 0, "p[0].b[0] = 7\n", "", false},
		{"no limits", {"SCHEMA", "INPUT", "--max-steps=0", "--max-memory=0", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 0, "p[0].b[0] = 7\n", "", false},
		{"a bad --max-memory", {"SCHEMA", "INPUT", "--max-memory=1x"}, 2, "", `error: --max-memory must be bytes, or with K, M or G, not "1x"`, false},
		{"a bad --max-steps", {"SCHEMA", "INPUT", "--max-steps=-1"}, 2, "", `error: --max-steps must be a count, not "-1"`, false},
		{"a schema error", {"BAD", "INPUT"}, 1, "", ":5:11: Invalid: a: unknown type nope", false},
		{"no schema", {"NONE", "INPUT"}, 1, "", "error: cannot read /nonexistent/zelbyn_cli_test", false},
		{"no input", {"SCHEMA", "NONE", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 1, "", "error: cannot read /nonexistent/zelbyn_cli_test", false},
		{"output fails, as a tree", {"SCHEMA", "INPUT", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 1, "", "error: writing output: Short_Write", true},
		{"output fails, as JSON", {"SCHEMA", "INPUT", "--dump", "json", "--param", "count=2", "--param", "wide=true", "--param", "label=hi", "--param", "magic=cafe", "--param", "hdr=07"}, 1, "", "error: writing output: Short_Write", true},
	}
	for c in cases {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "zelbyn")
		for a in c.args {
			switch a {
			case "SCHEMA":
				append(&args, schema)
			case "BAD":
				append(&args, bad_schema)
			case "INPUT":
				append(&args, input)
			case "NONE":
				append(&args, "/nonexistent/zelbyn_cli_test")
			case:
				append(&args, a)
			}
		}

		r := run_cli(args[:], c.failing_stdout)
		testing.expectf(t, r.exit_code == c.exit_code, "%s: exit code %v, want %v; stderr: %s", c.name, r.exit_code, c.exit_code, r.stderr)
		if c.stdout == "" {
			testing.expectf(t, r.stdout == "", "%s: stdout not empty: %q", c.name, r.stdout)
		} else {
			testing.expectf(t, strings.contains(r.stdout, c.stdout), "%s: stdout %q, want it to contain %q", c.name, r.stdout, c.stdout)
		}
		if c.stderr == "" {
			testing.expectf(t, r.stderr == "", "%s: stderr not empty: %q", c.name, r.stderr)
		} else {
			testing.expectf(t, strings.contains(r.stderr, c.stderr), "%s: stderr %q, want it to contain %q", c.name, r.stderr, c.stderr)
		}
	}
}
