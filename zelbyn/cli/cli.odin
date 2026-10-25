// The command line of zelbyn: main.odin runs it on the process's
// arguments, stdout and stderr, and the tests on their own, so that its
// usage, errors and output can be checked without a process.
package cli

import "core:bufio"
import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../codegen"
import dmp "../dump"
import fld "../field"
import ksy "../ksy"
import mdata "../metadata"
import rdr "../reader"

Options :: struct {
	schema:      string `args:"pos=0,required" usage:"Schema: a Kaitai Struct .ksy file."`,
	file:        string `args:"pos=1,required" usage:"File to decode."`,
	dump:        string `usage:"Output form: tree or json (default tree)."`,
	offsets:     bool `usage:"With --dump tree: end each line with the value's offset in the file (@0x1A2B)."`,
	import_path: string `args:"name=import-path" usage:"Directories that absolute imports (/a/b) are found in, separated by ':' (';' on Windows)."`,
	max_memory:  string `args:"name=max-memory" usage:"The memory the decoded tree may take, beyond the file: bytes, or with K, M or G (default 1G); 0 for no limit."`,
	max_steps:   string `args:"name=max-steps" usage:"The steps the decode may take: elements, instances and value-instance evaluations (default 100000000); 0 for no limit."`,
}

// --param, which parse_args takes out of the command line before
// core:flags parses the rest: as a field of Options, a list of strings,
// core:flags costs every run some 7,000 instructions, 0.3% of decoding a
// small file, even when it is not given.
PARAM_USAGE :: "\t--param <string>, multiple   | An argument for a param of the schema's top-level type, name=value: an integer (decimal, or 0x, 0o or 0b), true or false, hex bytes (0a1b), also for a user type, which they are read as, or the text of a str. Give one for each param."


Dump_Kind :: enum {
	Tree,
	JSON,
}

// Parses the command line, with the values of its --params, each name=value,
// in params. When ok is false the program should exit with exit_code: 0
// after --help (usage on stdout), 2 on a usage error (message and usage on
// stderr).
parse_args :: proc(args: []string, stdout, stderr: io.Writer) -> (opts: Options, dump: Dump_Kind, params: []string, limits: rdr.Limits, exit_code: int, ok: bool) {
	opts = Options{dump = "tree"}
	program := filepath.base(args[0])

	rest := make([dynamic]string, context.temp_allocator)
	given := make([dynamic]string, context.temp_allocator)
	for i := 1; i < len(args); i += 1 {
		switch {
		case args[i] == "--param":
			if i + 1 == len(args) {
				fmt.wprintln(stderr, "error: --param needs name=value")
				write_usage(stderr, program)
				return opts, dump, nil, limits, 2, false
			}
			i += 1
			append(&given, args[i])
		case strings.has_prefix(args[i], "--param="):
			append(&given, args[i][len("--param="):])
		case:
			append(&rest, args[i])
		}
	}
	params = given[:]

	if err := flags.parse(&opts, rest[:], .Unix, allocator = context.temp_allocator); err != nil {
		print_flags_error(stdout, stderr, err, program)
		if _, is_help := err.(flags.Help_Request); is_help {
			fmt.wprintln(stdout, PARAM_USAGE)
			return opts, dump, params, limits, 0, false
		}

		write_usage(stderr, program)
		return opts, dump, params, limits, 2, false
	}

	switch opts.dump {
	case "tree":
		dump = .Tree
	case "json":
		dump = .JSON
	case:
		fmt.wprintfln(stderr, "error: --dump must be tree or json, not %q", opts.dump)
		write_usage(stderr, program)
		return opts, dump, params, limits, 2, false
	}
	if opts.offsets && dump != .Tree {
		fmt.wprintln(stderr, "error: --offsets applies only to --dump tree")
		write_usage(stderr, program)
		return opts, dump, params, limits, 2, false
	}

	limits = rdr.DEFAULT_LIMITS
	if opts.max_memory != "" {
		n, is_size := size_value(opts.max_memory)
		if !is_size {
			fmt.wprintfln(stderr, "error: --max-memory must be bytes, or with K, M or G, not %q", opts.max_memory)
			write_usage(stderr, program)
			return opts, dump, params, limits, 2, false
		}
		limits.max_memory = n
	}
	if opts.max_steps != "" {
		n, is_count := strconv.parse_int(opts.max_steps, 10)
		if !is_count || n < 0 {
			fmt.wprintfln(stderr, "error: --max-steps must be a count, not %q", opts.max_steps)
			write_usage(stderr, program)
			return opts, dump, params, limits, 2, false
		}
		limits.max_steps = n
	}

	return opts, dump, params, limits, 0, true
}

// Writes err, from flags.parse, as flags.print_errors does, but to stderr,
// or after --help, the usage of Options to stdout: print_errors writes to
// the process's own. Options has no file to open, so no Open_File_Error.
print_flags_error :: proc(stdout, stderr: io.Writer, err: flags.Error, program: string) {
	switch e in err {
	case flags.Parse_Error:
		fmt.wprintfln(stderr, "[%T.%v] %s", e, e.reason, e.message)
	case flags.Open_File_Error:
		fmt.wprintfln(stderr, "[%T#%i] Unable to open %q", e, e.errno, e.filename)
	case flags.Validation_Error:
		fmt.wprintfln(stderr, "[%T] %s", e, e.message)
	case flags.Help_Request:
		flags.write_usage(stdout, Options, program, .Unix)
	}
}

// Writes the usage of the command line to w: that of Options, then --param.
write_usage :: proc(w: io.Writer, program: string) {
	flags.write_usage(w, Options, program, .Unix)
	fmt.wprintln(w, PARAM_USAGE)
}

// The options of zelbyn gen, which writes Odin code that decodes the schema.
Gen_Options :: struct {
	schema:       string `args:"pos=0,required" usage:"Schema: a Kaitai Struct .ksy file."`,
	out:          string `args:"required" usage:"Directory to write the package to, as <package>.odin; made if it does not exist."`,
	import_path:  string `args:"name=import-path" usage:"Directories that absolute imports (/a/b) are found in, separated by ':' (';' on Windows)."`,
	package_name: string `args:"name=package" usage:"The package's name (default: the schema's meta id)."`,
	runtime:      string `usage:"The import path of zelbyn's package data, which the code imports (default zelbyn:data)."`,
}

// Runs zelbyn gen, args being what follows gen: writes the package that
// decodes the schema. Returns the exit code: 0 on success and after --help,
// 1 when the format cannot be loaded or the code written, and 2 on a usage
// error.
gen :: proc(program: string, args: []string, stdout, stderr: io.Writer) -> int {
	opts: Gen_Options
	usage := fmt.tprintf("%s gen", program)
	if err := flags.parse(&opts, args, .Unix, allocator = context.temp_allocator); err != nil {
		print_gen_error(stdout, stderr, err, usage)
		if _, is_help := err.(flags.Help_Request); is_help do return 0
		flags.write_usage(stderr, Gen_Options, usage, .Unix)
		return 2
	}

	file_format: mdata.File_Format
	defer mdata.destroy_file_format(&file_format)
	import_paths, _ := filepath.split_list(opts.import_path, context.temp_allocator)
	if !load_format(opts.schema, import_paths, &file_format, stderr) do return 1

	code, gen_err := codegen.generate(&file_format, {package_name = opts.package_name, runtime = opts.runtime})
	defer delete(code)
	defer codegen.destroy_error(&gen_err)
	if gen_err.message != "" {
		fmt.wprintfln(stderr, "error: %s: cannot generate code: %s", opts.schema, gen_err.message)
		return 1
	}

	name := opts.package_name != "" ? opts.package_name : file_format.root.ref_name
	if err := os.make_directory_all(opts.out); err != nil && !os.is_dir(opts.out) {
		fmt.wprintfln(stderr, "error: cannot make %s: %v", opts.out, err)
		return 1
	}
	path, _ := filepath.join({opts.out, fmt.tprintf("%s.odin", name)}, context.temp_allocator)
	if err := os.write_entire_file(path, code); err != nil {
		fmt.wprintfln(stderr, "error: cannot write %s: %v", path, err)
		return 1
	}
	return 0
}

// As print_flags_error, for zelbyn gen.
@(private = "file")
print_gen_error :: proc(stdout, stderr: io.Writer, err: flags.Error, usage: string) {
	switch e in err {
	case flags.Parse_Error:
		fmt.wprintfln(stderr, "[%T.%v] %s", e, e.reason, e.message)
	case flags.Open_File_Error:
		fmt.wprintfln(stderr, "[%T#%i] Unable to open %q", e, e.errno, e.filename)
	case flags.Validation_Error:
		fmt.wprintfln(stderr, "[%T] %s", e, e.message)
	case flags.Help_Request:
		flags.write_usage(stdout, Gen_Options, usage, .Unix)
	}
}

// Runs the command line args (args[0] the program's name): parses it and,
// unless it asks for the usage or is wrong, decodes the file it names and
// writes the dump to stdout. Messages go to stderr. Returns the exit code:
// 0 on success and after --help, 1 when the format cannot be loaded or the
// file read or decoded, or the output written, and 2 on a usage error.
execute :: proc(args: []string, stdout, stderr: io.Writer) -> (exit_code: int) {
	if len(args) > 1 && args[1] == "gen" do return gen(filepath.base(args[0]), args[2:], stdout, stderr)
	opts, dump, params, limits, usage_exit, ok := parse_args(args, stdout, stderr)
	if !ok do return usage_exit
	return run(opts.schema, opts.file, opts.import_path, dump, opts.offsets, params, limits, stdout, stderr)
}

// Loads the format from schema_path, with absolute imports found in the
// directories of the list import_path, decodes file_path with it and writes
// the decoded tree to stdout as a text dump, with each value's offset when
// offsets is set, or JSON. Errors are reported on stderr, and nothing is
// written to stdout unless decoding succeeds. params are the arguments of
// the params of the schema's top-level type, as name=value. Returns 0 on
// success, 1 on a load, parse or output error, and 2 when params do not
// give one argument for each param.
run :: proc(schema_path: string, file_path: string, import_path: string, dump: Dump_Kind, offsets: bool, params: []string, limits: rdr.Limits, stdout, stderr: io.Writer) -> int {
	file_format: mdata.File_Format
	defer mdata.destroy_file_format(&file_format)

	import_paths, _ := filepath.split_list(import_path, context.temp_allocator)
	if !load_format(schema_path, import_paths, &file_format, stderr) do return 1
	args, args_ok := root_args(file_format.root, params, stderr)
	if !args_ok do return 2
	defer delete(args)

	tree: fld.Value_Tree
	// the tree may be partially filled after a parse error; free it either way
	defer fld.destroy_value_tree(&tree)

	_, parse_err := rdr.read(file_path, &file_format, &tree, spans = offsets, args = args, limits = limits)
	defer rdr.destroy_parse_error(&parse_err)

	if parse_err.kind == .File_Read_Failed {
		fmt.wprintfln(stderr, "error: cannot read %s: %v", file_path, parse_err.os_error)
		return 1
	} else if parse_err.kind != .None {
		fmt.wprintf(stderr, "error: %v at 0x%08X in %s", parse_err.kind, parse_err.offset, parse_err.path)
		write_check_values(stderr, parse_err)
		fmt.wprintln(stderr)
		return 1
	}

	out: bufio.Writer
	bufio.writer_init(&out, stdout)
	defer bufio.writer_destroy(&out)

	w := bufio.writer_to_writer(&out)
	write_err: io.Error
	switch dump {
	case .Tree:
		write_err = dmp.write_text(w, &file_format, &tree, offsets)
	case .JSON:
		write_err = dmp.write_json(w, &file_format, &tree)
	}
	if write_err == .None do write_err = bufio.writer_flush(&out)

	if write_err != .None {
		fmt.wprintfln(stderr, "error: writing output: %v", write_err)
		return 1
	}

	return 0
}

// The arguments that params, each name=value, give the params of root, the
// set of the schema's top-level type, in their order, with byte arrays in
// context.temp_allocator. ok is false, with the error reported on stderr,
// unless there is one valid argument for each param.
root_args :: proc(root: ^mdata.Node, params: []string, stderr: io.Writer) -> (args: []fld.Value, ok: bool) {
	args = make([]fld.Value, len(root.params))
	given := make([]bool, len(root.params), context.temp_allocator)
	defer if !ok do delete(args)
	for param in params {
		eq := strings.index_byte(param, '=')
		if eq < 0 {
			fmt.wprintfln(stderr, "error: --param %s is not name=value", param)
			return
		}
		name, text := param[:eq], param[eq + 1:]
		k := -1
		for p, i in root.params {
			if p.ref_name == name do k = i
		}
		if k < 0 {
			fmt.wprintfln(stderr, "error: --param %s: the schema's top-level type has no param %s", param, name)
			return
		}
		if given[k] {
			fmt.wprintfln(stderr, "error: --param %s: param %s is given twice", param, name)
			return
		}
		given[k] = true
		#partial switch root.params[k].type {
		case .Int64:
			n, is_int := strconv.parse_i64_maybe_prefixed(text)
			if !is_int {
				fmt.wprintfln(stderr, "error: --param %s: %s is an integer, not %q", param, name, text)
				return
			}
			args[k] = n
		case .Bool:
			if text != "true" && text != "false" {
				fmt.wprintfln(stderr, "error: --param %s: %s is true or false, not %q", param, name, text)
				return
			}
			args[k] = text == "true"
		case .Blob, .Set:
			// the bytes of a user type are read as an instance of it
			bytes, is_hex := hex_bytes(text)
			if !is_hex {
				fmt.wprintfln(stderr, "error: --param %s: %s is bytes, in hex (0a1b), not %q", param, name, text)
				return
			}
			args[k] = bytes
		case .String:
			args[k] = text
		}
	}
	for p, i in root.params {
		if !given[i] {
			fmt.wprintfln(stderr, "error: the schema's top-level type needs --param %s=value", p.ref_name)
			return
		}
	}
	return args, true
}

// The bytes that text gives, a count of them with an optional K, M or G
// (2^10, 2^20 or 2^30); ok is false for anything else, or one beyond an
// int.
size_value :: proc(text: string) -> (n: int, ok: bool) {
	digits, unit := text, 1
	if len(text) > 0 {
		switch text[len(text) - 1] {
		case 'K', 'k':
			unit = 1 << 10
		case 'M', 'm':
			unit = 1 << 20
		case 'G', 'g':
			unit = 1 << 30
		}
		if unit != 1 do digits = text[:len(text) - 1]
	}
	if len(digits) == 0 do return
	for c in digits do if c < '0' || c > '9' do return
	count := strconv.parse_int(digits, 10) or_return
	if count > max(int) / unit do return
	return count * unit, true
}

// The bytes that text gives as pairs of hex digits, in
// context.temp_allocator.
hex_bytes :: proc(text: string) -> (bytes: []byte, ok: bool) {
	if len(text) % 2 != 0 do return
	bytes = make([]byte, len(text) / 2, context.temp_allocator)
	for i in 0 ..< len(bytes) {
		high := hex_digit(text[2 * i]) or_return
		low := hex_digit(text[2 * i + 1]) or_return
		bytes[i] = high << 4 | low
	}
	return bytes, true
}

hex_digit :: proc(c: byte) -> (v: byte, ok: bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return
}

// Loads file_format from schema_path, reporting any error on stderr with
// the file it is in: the schema, or one it imports.
load_format :: proc(schema_path: string, import_paths: []string, file_format: ^mdata.File_Format, stderr: io.Writer) -> bool {
	err := ksy.read_file_format(schema_path, file_format, import_paths)
	defer ksy.destroy_error(&err)

	file := err.path != "" ? err.path : schema_path
	switch {
	case err.kind == .None:
		return true
	case err.kind == .Read_Failed:
		fmt.wprintfln(stderr, "error: cannot read %s: %v", file, err.os_error)
	case err.line == 0:
		fmt.wprintfln(stderr, "error: %s: %v: %s", file, err.kind, err.message)
	case:
		fmt.wprintfln(stderr, "error: %s:%v:%v: %v: %s", file, err.line, err.column, err.kind, err.message)
	}
	return false
}

// Writes what a failed check read and expected, after its error:
// ": read 4, expected one of 1, 2", or nothing for another error.
@(private = "file")
write_check_values :: proc(w: io.Writer, err: rdr.Parse_Error) {
	if err.value != "" do fmt.wprintf(w, ": read %s", err.value)
	if err.expected == "" do return
	fmt.wprint(w, err.value != "" ? ", expected " : ": expected ")
	#partial switch err.kind {
	case .Less_Than_Min:
		fmt.wprint(w, "at least ")
	case .Greater_Than_Max:
		fmt.wprint(w, "at most ")
	case .Not_Any_Of, .Not_In_Enum:
		fmt.wprint(w, "one of ")
	}
	fmt.wprint(w, err.expected)
}
