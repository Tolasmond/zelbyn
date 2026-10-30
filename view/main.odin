// zelbyn-view: a viewer of a file decoded with a schema, in the terminal.
// It runs on Linux only, as hnoss, the library it draws with (a submodule
// in view/hnoss), does. It shows the decoded tree as an outline
// (view/outline) of its rows (view/rows).
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../zelbyn/cli"
import fld "../zelbyn/field"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "hnoss"
import "outline"
import "rows"

USAGE :: "Usage: %s <schema.ksy> <file>\n"

main :: proc() {
	os.exit(run(os.args)) // os.exit skips defers: run has already cleaned up
}

// Runs the command line args (args[0] the program's name): loads the
// schema, decodes the file, and shows it until the user quits. A schema or
// decode error is reported on stderr as zelbyn reports it, before the
// terminal is taken. Returns the exit code: 0 on success and after --help,
// 1 on an error, and 2 on a usage error.
run :: proc(args: []string) -> int {
	program := filepath.base(args[0])
	if len(args) == 2 && (args[1] == "--help" || args[1] == "-h") {
		fmt.printf(USAGE, program)
		return 0
	}
	if len(args) != 3 {
		fmt.eprintf(USAGE, program)
		return 2
	}
	schema_path, file_path := args[1], args[2]
	stderr := os.to_stream(os.stderr)

	file_format: mdata.File_Format
	defer mdata.destroy_file_format(&file_format)
	if !cli.load_format(schema_path, nil, &file_format, stderr) do return 1

	// read here, not by reader.read, to keep the bytes for the hex pane
	data, read_err := os.read_entire_file(file_path, context.allocator)
	// a read that fails part way may have allocated
	defer delete(data)
	if read_err != nil {
		cli.write_parse_error(stderr, file_path, {kind = .File_Read_Failed, os_error = read_err})
		return 1
	}

	tree: fld.Value_Tree
	// the tree may be partially filled after a parse error; free it either way
	defer fld.destroy_value_tree(&tree)
	_, parse_err := rdr.read_from_bytes(data, &file_format, &tree, spans = true)
	defer rdr.destroy_parse_error(&parse_err)
	if parse_err.kind != .None {
		cli.write_parse_error(stderr, file_path, parse_err)
		return 1
	}

	model: rows.Model
	rows.init(&model, &file_format, &tree)
	defer rows.destroy(&model)

	// show has given the terminal back by now, so the message is seen
	if err := show(file_path, &model, len(data)); err != .None {
		fmt.eprintfln("error: terminal: %v", err)
		return 1
	}
	return 0
}

// Takes the terminal and shows the rows of model, of a file of size bytes,
// in an outline titled with file_path, until q, Esc or Ctrl+C, then gives
// the terminal back.
show :: proc(file_path: string, model: ^rows.Model, size: int) -> hnoss.Error {
	context.assertion_failure_proc = hnoss.assertion_failure_proc
	term := hnoss.init(hnoss.DEFAULT_OPTIONS + {.Mouse_Capture}) or_return
	defer hnoss.deinit(&term)

	// the title is markup, in which [[ is a literal [; it lasts every frame,
	// so not in context.temp_allocator, which each frame frees
	title, allocated := strings.replace_all(filepath.base(file_path), "[", "[[")
	defer if allocated do delete(title)
	tree := outline.State{model = model, digits = outline.offset_digits(size)}
	events: []hnoss.Event
	loop: for {
		f := hnoss.begin_frame(&term)
		ui := hnoss.ui(f, events)
		area := f.area
		footer := hnoss.cut_bottom(&area, 1)
		hnoss.focus(ui, &tree)
		inner := hnoss.box(ui, area, title, {focused = true})
		outline.draw(ui, inner, &tree)
		hnoss.label(ui, footer, fmt.tprintf("[dim]row %d of %d · ↑↓ jk PgUp PgDn Home End move · → l ← h Enter expand, collapse · q quit[/]", tree.selected + 1, rows.count(model)))
		for ev in hnoss.unhandled(ui) {
			if hnoss.is_char(ev, 'q') || hnoss.is_key(ev, .Esc) || hnoss.is_char(ev, 'c', {.Ctrl}) do break loop
		}
		hnoss.end_frame(&term) or_return
		free_all(context.temp_allocator)
		events = hnoss.poll_events(&term, -1)
		if term.error != .None do return term.error
	}
	return .None
}
