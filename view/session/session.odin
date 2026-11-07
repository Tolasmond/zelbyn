// Package session is what the viewer shows, made from its command line:
// the schema loaded, the file read and decoded, and the rows of its tree.
// It takes the command line as zelbyn does (zelbyn/cli), and reports
// errors with zelbyn's messages and exit codes. It imports no terminal
// library, so it is tested on every platform.
package session

import "core:flags"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../../zelbyn/cli"
import fld "../../zelbyn/field"
import mdata "../../zelbyn/metadata"
import rdr "../../zelbyn/reader"
import "../rows"

Options :: struct {
	schema:      string `args:"pos=0,required" usage:"Schema: a Kaitai Struct .ksy file."`,
	file:        string `args:"pos=1,required" usage:"File to view."`,
	import_path: string `args:"name=import-path" usage:"Directories that absolute imports (/a/b) are found in, separated by ':' (';' on Windows)."`,
	max_memory:  string `args:"name=max-memory" usage:"The memory the decoded tree may take, beyond the file: bytes, or with K, M or G (default 1G); 0 for no limit."`,
	max_steps:   string `args:"name=max-steps" usage:"The steps the decode may take: elements, instances and value-instance evaluations (default 100000000); 0 for no limit."`,
}

// A file decoded for the viewer. When the decode failed, err is its error,
// and the tree holds what was read before it (doc/arch.md §7.10).
Session :: struct {
	file_path: string,
	format:    mdata.File_Format,
	data:      []byte,
	tree:      fld.Value_Tree,
	err:       rdr.Parse_Error,
	limits:    rdr.Limits,
	model:     rows.Model,
}

// Writes the usage of the viewer's command line to w: that of Options,
// then --param, as zelbyn takes it.
write_usage :: proc(w: io.Writer, program: string) {
	flags.write_usage(w, Options, program, .Unix)
	fmt.wprintln(w, cli.PARAM_USAGE)
}

// Makes s from the command line args (args[0] the program's name): takes
// its options as zelbyn does, loads the schema, reads the file and decodes
// it with spans, and makes the rows of its tree. A decode that fails still
// gives a session, with its error. Returns, when the viewer should not
// start, ok false and the exit code: 0 after --help (usage on stdout), 1
// when the schema cannot be loaded or the file read, and 2 on a usage
// error, with zelbyn's messages on stderr. s is destroyed with destroy,
// whatever this returns.
make_session :: proc(s: ^Session, args: []string, stdout, stderr: io.Writer) -> (exit_code: int, ok: bool) {
	program := filepath.base(args[0])
	rest, params, params_ok := cli.split_params(args[1:], stderr)
	if !params_ok {
		write_usage(stderr, program)
		return 2, false
	}
	opts: Options
	if err := flags.parse(&opts, rest, .Unix, allocator = context.temp_allocator); err != nil {
		cli.print_flags_error(stdout, stderr, err, program, Options)
		if _, is_help := err.(flags.Help_Request); is_help {
			fmt.wprintln(stdout, cli.PARAM_USAGE)
			return 0, false
		}
		write_usage(stderr, program)
		return 2, false
	}
	limits_ok: bool
	s.limits, limits_ok = cli.parse_limits(opts.max_memory, opts.max_steps, stderr)
	if !limits_ok {
		write_usage(stderr, program)
		return 2, false
	}

	import_paths, _ := filepath.split_list(opts.import_path, context.temp_allocator)
	if !cli.load_format(opts.schema, import_paths, &s.format, stderr) do return 1, false
	root_args, args_ok := cli.root_args(s.format.root, params, stderr)
	if !args_ok do return 2, false
	// the tree copies them
	defer delete(root_args)

	s.file_path = strings.clone(opts.file)
	read_err: os.Error
	s.data, read_err = os.read_entire_file(opts.file, context.allocator)
	if read_err != nil {
		cli.write_parse_error(stderr, opts.file, {kind = .File_Read_Failed, os_error = read_err})
		return 1, false
	}
	_, s.err = rdr.read_from_bytes(s.data, &s.format, &s.tree, spans = true, args = root_args, limits = s.limits)
	rows.init(&s.model, &s.format, &s.tree)
	return 0, true
}

destroy :: proc(s: ^Session) {
	rows.destroy(&s.model)
	rdr.destroy_parse_error(&s.err)
	fld.destroy_value_tree(&s.tree)
	delete(s.data)
	delete(s.file_path)
	mdata.destroy_file_format(&s.format)
	s^ = {}
}

// The decode's error as zelbyn writes it, without "error: " and its line
// break, and for a limit reached, which option sets it; "" when the decode
// succeeded. In allocator.
error_text :: proc(s: ^Session, allocator := context.temp_allocator) -> string {
	if s.err.kind == .None do return ""
	b := strings.builder_make(context.temp_allocator)
	cli.write_parse_error(strings.to_writer(&b), s.file_path, s.err)
	text := strings.trim_suffix(strings.trim_prefix(strings.to_string(b), "error: "), "\n")
	#partial switch s.err.kind {
	case .Step_Limit:
		text = fmt.tprintf("%s: the decode took more than %d steps (--max-steps)", text, s.limits.max_steps)
	case .Memory_Limit:
		text = fmt.tprintf("%s: the tree took more than %d bytes, or there was no memory left (--max-memory)", text, s.limits.max_memory)
	}
	return strings.clone(text, allocator)
}
