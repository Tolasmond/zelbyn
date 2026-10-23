package main

import "core:bufio"
import "core:flags"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import dmp "zelbyn/dump"
import fld "zelbyn/field"
import ksy "zelbyn/ksy"
import mdat "zelbyn/metadata"
import rdr "zelbyn/reader"

Options :: struct {
	schema:      string `args:"pos=0,required" usage:"Schema: a Kaitai Struct .ksy file."`,
	file:        string `args:"pos=1,required" usage:"File to decode."`,
	dump:        string `usage:"Output form: tree or json (default tree)."`,
	offsets:     bool `usage:"With --dump tree: end each line with the value's offset in the file (@0x1A2B)."`,
	import_path: string `args:"name=import-path" usage:"Directories that absolute imports (/a/b) are found in, separated by ':' (';' on Windows)."`,
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

main :: proc() {
	context.logger = log.create_file_logger(os.stderr, lowest = .Warning)

	opts, dump, params, usage_exit, ok := parse_args(os.args)
	if !ok do os.exit(usage_exit)

	exit_code := run_tracked(opts.schema, opts.file, opts.import_path, dump, opts.offsets, params)

	os.exit(exit_code) // os.exit skips defers: run_tracked has already cleaned up
}

// Parses the command line, with the values of its --params, each name=value,
// in params. When ok is false the program should exit with exit_code: 0
// after --help (usage on stdout), 2 on a usage error (message and usage on
// stderr).
parse_args :: proc(args: []string) -> (opts: Options, dump: Dump_Kind, params: []string, exit_code: int, ok: bool) {
	opts = Options{dump = "tree"}
	program := filepath.base(args[0])
	stderr := os.to_stream(os.stderr)

	rest := make([dynamic]string, context.temp_allocator)
	given := make([dynamic]string, context.temp_allocator)
	for i := 1; i < len(args); i += 1 {
		switch {
		case args[i] == "--param":
			if i + 1 == len(args) {
				fmt.eprintln("error: --param needs name=value")
				write_usage(stderr, program)
				return opts, dump, nil, 2, false
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
		flags.print_errors(Options, err, program, .Unix)
		if _, is_help := err.(flags.Help_Request); is_help {
			fmt.println(PARAM_USAGE)
			return opts, dump, params, 0, false
		}

		write_usage(stderr, program)
		return opts, dump, params, 2, false
	}

	switch opts.dump {
	case "tree":
		dump = .Tree
	case "json":
		dump = .JSON
	case:
		fmt.eprintfln("error: --dump must be tree or json, not %q", opts.dump)
		write_usage(stderr, program)
		return opts, dump, params, 2, false
	}
	if opts.offsets && dump != .Tree {
		fmt.eprintln("error: --offsets applies only to --dump tree")
		write_usage(stderr, program)
		return opts, dump, params, 2, false
	}

	return opts, dump, params, 0, true
}

// Writes the usage of the command line to w: that of Options, then --param.
write_usage :: proc(w: io.Writer, program: string) {
	flags.write_usage(w, Options, program, .Unix)
	fmt.wprintln(w, PARAM_USAGE)
}

// Calls run. In debug builds (-debug) it runs under a tracking allocator and
// reports leaks and bad frees on stderr, either of which turns exit code 0
// into 1.
run_tracked :: proc(schema_path: string, file_path: string, import_path: string, dump: Dump_Kind, offsets: bool, params: []string) -> int {
	when ODIN_DEBUG {
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, context.allocator)
		tracking_allocator.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		exit_code := run(schema_path, file_path, import_path, dump, offsets, params)

		if reset_tracking_allocator(&tracking_allocator) && exit_code == 0 {
			exit_code = 1
		}
		mem.tracking_allocator_destroy(&tracking_allocator)
		return exit_code
	} else {
		return run(schema_path, file_path, import_path, dump, offsets, params)
	}
}

// Loads the format from schema_path, with absolute imports found in the
// directories of the list import_path, decodes file_path with it and writes
// the decoded tree to stdout as a text dump, with each value's offset when
// offsets is set, or JSON. Errors are reported on stderr, and nothing is
// written to stdout unless decoding succeeds. params are the arguments of
// the params of the schema's top-level type, as name=value. Returns 0 on
// success, 1 on a load, parse or output error, and 2 when params do not
// give one argument for each param.
run :: proc(schema_path: string, file_path: string, import_path: string, dump: Dump_Kind, offsets: bool, params: []string) -> int {
	file_format: mdat.File_Format
	defer mdat.destroy_file_format(&file_format)

	import_paths, _ := filepath.split_list(import_path, context.temp_allocator)
	if !load_format(schema_path, import_paths, &file_format) do return 1
	args, args_ok := root_args(file_format.root, params)
	if !args_ok do return 2
	defer delete(args)

	tree: fld.Value_Tree
	// the tree may be partially filled after a parse error; free it either way
	defer fld.destroy_value_tree(&tree)

	_, parse_err := rdr.read(file_path, &file_format, &tree, spans = offsets, args = args)
	defer rdr.destroy_parse_error(&parse_err)

	if parse_err.kind == .File_Read_Failed {
		fmt.eprintfln("error: cannot read %s: %v", file_path, parse_err.os_error)
		return 1
	} else if parse_err.kind != .None {
		fmt.eprintfln("error: %v at 0x%08X in %s", parse_err.kind, parse_err.offset, parse_err.path)
		return 1
	}

	out: bufio.Writer
	bufio.writer_init(&out, os.to_stream(os.stdout))
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
		fmt.eprintfln("error: writing output: %v", write_err)
		return 1
	}

	return 0
}

// The arguments that params, each name=value, give the params of root, the
// set of the schema's top-level type, in their order, with byte arrays in
// context.temp_allocator. ok is false, with the error reported on stderr,
// unless there is one valid argument for each param.
root_args :: proc(root: ^mdat.Node, params: []string) -> (args: []fld.Value, ok: bool) {
	args = make([]fld.Value, len(root.params))
	given := make([]bool, len(root.params), context.temp_allocator)
	defer if !ok do delete(args)
	for param in params {
		eq := strings.index_byte(param, '=')
		if eq < 0 {
			fmt.eprintfln("error: --param %s is not name=value", param)
			return
		}
		name, text := param[:eq], param[eq + 1:]
		k := -1
		for p, i in root.params {
			if p.ref_name == name do k = i
		}
		if k < 0 {
			fmt.eprintfln("error: --param %s: the schema's top-level type has no param %s", param, name)
			return
		}
		if given[k] {
			fmt.eprintfln("error: --param %s: param %s is given twice", param, name)
			return
		}
		given[k] = true
		#partial switch root.params[k].type {
		case .Int64:
			n, is_int := strconv.parse_i64_maybe_prefixed(text)
			if !is_int {
				fmt.eprintfln("error: --param %s: %s is an integer, not %q", param, name, text)
				return
			}
			args[k] = n
		case .Bool:
			if text != "true" && text != "false" {
				fmt.eprintfln("error: --param %s: %s is true or false, not %q", param, name, text)
				return
			}
			args[k] = text == "true"
		case .Blob, .Set:
			// the bytes of a user type are read as an instance of it
			bytes, is_hex := hex_bytes(text)
			if !is_hex {
				fmt.eprintfln("error: --param %s: %s is bytes, in hex (0a1b), not %q", param, name, text)
				return
			}
			args[k] = bytes
		case .String:
			args[k] = text
		}
	}
	for p, i in root.params {
		if !given[i] {
			fmt.eprintfln("error: the schema's top-level type needs --param %s=value", p.ref_name)
			return
		}
	}
	return args, true
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
load_format :: proc(schema_path: string, import_paths: []string, file_format: ^mdat.File_Format) -> bool {
	err := ksy.read_file_format(schema_path, file_format, import_paths)
	defer ksy.destroy_error(&err)

	file := err.path != "" ? err.path : schema_path
	switch {
	case err.kind == .None:
		return true
	case err.kind == .Read_Failed:
		fmt.eprintfln("error: cannot read %s: %v", file, err.os_error)
	case err.line == 0:
		fmt.eprintfln("error: %s: %v: %s", file, err.kind, err.message)
	case:
		fmt.eprintfln("error: %s:%v:%v: %v: %s", file, err.line, err.column, err.kind, err.message)
	}
	return false
}

reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
	leaks := false

	if len(a.allocation_map) != 0 {
		fmt.eprintfln("%v leaks found!", len(a.allocation_map))
	}

	for _, value in a.allocation_map {
		fmt.eprintfln("%v: Leaked %v bytes", value.location, value.size)
		leaks = true
	}

	if len(a.bad_free_array) != 0 {
		fmt.eprintfln("%v bad frees found!", len(a.bad_free_array))
	}

	for entry in a.bad_free_array {
		fmt.eprintfln("%v: Bad free of %p", entry.location, entry.memory)
		leaks = true
	}

	mem.tracking_allocator_clear(a)
	return leaks
}
