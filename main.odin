package main

import "core:bufio"
import "core:flags"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import dmp "gnrcrdr/dump"
import fld "gnrcrdr/field"
import mdat "gnrcrdr/metadata"
import rdr "gnrcrdr/reader"
import sql "gnrcrdr/sqlite"

Options :: struct {
	schema: string `args:"pos=0,required" usage:"Schema database (SQLite)."`,
	file:   string `args:"pos=1,required" usage:"File to decode."`,
	format: int    `usage:"Format id in the schema (default 1)."`,
	dump:   string `usage:"Output form: tree or json (default tree)."`,
}

Dump_Kind :: enum {
	Tree,
	JSON,
}

main :: proc() {
	context.logger = log.create_file_logger(os.stderr, lowest = .Warning)

	opts, dump, usage_exit, ok := parse_args(os.args)
	if !ok do os.exit(usage_exit)

	exit_code := run_tracked(opts.schema, opts.format, opts.file, dump)

	os.exit(exit_code) // os.exit skips defers: run_tracked has already cleaned up
}

// Parses the command line. When ok is false the program should exit with
// exit_code: 0 after --help (usage on stdout), 2 on a usage error (message
// and usage on stderr).
parse_args :: proc(args: []string) -> (opts: Options, dump: Dump_Kind, exit_code: int, ok: bool) {
	opts = Options{format = 1, dump = "tree"}
	program := filepath.base(args[0])
	stderr := os.to_stream(os.stderr)

	if err := flags.parse(&opts, args[1:], .Unix, allocator = context.temp_allocator); err != nil {
		flags.print_errors(Options, err, program, .Unix)
		if _, is_help := err.(flags.Help_Request); is_help do return opts, dump, 0, false

		flags.write_usage(stderr, Options, program, .Unix)
		return opts, dump, 2, false
	}

	switch opts.dump {
	case "tree":
		dump = .Tree
	case "json":
		dump = .JSON
	case:
		fmt.eprintfln("error: --dump must be tree or json, not %q", opts.dump)
		flags.write_usage(stderr, Options, program, .Unix)
		return opts, dump, 2, false
	}

	return opts, dump, 0, true
}

// Calls run. In debug builds (-debug) it runs under a tracking allocator and
// reports leaks and bad frees on stderr, either of which turns exit code 0
// into 1.
run_tracked :: proc(db_path: string, format_id: int, file_path: string, dump: Dump_Kind) -> int {
	when ODIN_DEBUG {
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, context.allocator)
		tracking_allocator.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		exit_code := run(db_path, format_id, file_path, dump)

		if reset_tracking_allocator(&tracking_allocator) && exit_code == 0 {
			exit_code = 1
		}
		mem.tracking_allocator_destroy(&tracking_allocator)
		return exit_code
	} else {
		return run(db_path, format_id, file_path, dump)
	}
}

// Loads format format_id from db_path, decodes file_path with it and writes
// the decoded tree to stdout as a text dump or JSON. Errors are reported on
// stderr, and nothing is written to stdout unless decoding succeeds. Returns
// 0 on success, 1 on a load, parse or output error.
run :: proc(db_path: string, format_id: int, file_path: string, dump: Dump_Kind) -> int {
	file_format: mdat.File_Format
	defer mdat.destroy_file_format(&file_format)

	load_err := sql.read_file_format(db_path, format_id, &file_format)
	defer sql.destroy_load_error(&load_err)

	if load_err.kind != .None {
		fmt.eprintfln(
			"error: loading format %v from %s: %v (%v, table %s): %s",
			format_id,
			db_path,
			load_err.kind,
			load_err.code,
			load_err.table,
			load_err.message)
		return 1
	}

	tree: fld.Value_Tree
	// the tree may be partially filled after a parse error; free it either way
	defer fld.destroy_value_tree(&tree)

	_, parse_err := rdr.read(file_path, &file_format, &tree)
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
		write_err = dmp.write_text(w, &file_format, &tree)
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
