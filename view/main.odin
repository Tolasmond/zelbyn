// zelbyn-view: a viewer of a file decoded with a schema, in the terminal.
// It runs on Linux only, as hnoss, the library it draws with (a submodule
// in view/hnoss), does. It shows the decoded tree as an outline
// (view/outline) of its rows (view/rows), beside the file's bytes
// (view/hexdump), those of the selected row highlighted.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../zelbyn/cli"
import fld "../zelbyn/field"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "hexdump"
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
	if err := show(file_path, &model, data); err != .None {
		fmt.eprintfln("error: terminal: %v", err)
		return 1
	}
	return 0
}

// Takes the terminal and shows the rows of model, the tree of data, in an
// outline titled with file_path, beside data's bytes, until q, Esc or
// Ctrl+C, then gives the terminal back. Tab moves the focus between them.
show :: proc(file_path: string, model: ^rows.Model, data: []byte) -> hnoss.Error {
	context.assertion_failure_proc = hnoss.assertion_failure_proc
	term := hnoss.init(hnoss.DEFAULT_OPTIONS + {.Mouse_Capture}) or_return
	defer hnoss.deinit(&term)

	// the title is markup, in which [[ is a literal [; it lasts every frame,
	// so not in context.temp_allocator, which each frame frees
	title, allocated := strings.replace_all(filepath.base(file_path), "[", "[[")
	defer if allocated do delete(title)
	digits := outline.offset_digits(len(data))
	tree := outline.State{model = model, digits = digits}
	bytes := hexdump.State{data = data, digits = digits, follow = 0}
	shown: hexdump.Highlight
	events: []hnoss.Event
	loop: for {
		f := hnoss.begin_frame(&term)
		ui := hnoss.ui(f, events)
		hnoss.focus_order(ui, {&tree, &bytes})
		area := f.area
		footer := hnoss.cut_bottom(&area, 1)
		// the bytes at 16 a line when they fit beside 30 columns of tree
		hex_width := hexdump.line_width(16, digits) + 3
		right := area.width >= hex_width + 30 ? hnoss.cut_right(&area, hex_width) : hnoss.cut_right(&area, area.width / 2)

		inner := hnoss.box(ui, area, title, {focused = hnoss.focused(ui, &tree)})
		outline.draw(ui, inner, &tree)
		h, status := highlight(model, &tree)
		if h.value != shown.value || h.has_value != shown.has_value do bytes.follow = h.value.offset
		shown = h
		hex_inner := hnoss.box(ui, right, "bytes", {focused = hnoss.focused(ui, &bytes)})
		hexdump.draw(ui, hex_inner, &bytes, h)

		hnoss.label(ui, footer, fmt.tprintf("[dim]row %d of %d%s · ↑↓ jk PgUp PgDn Home End move · → l ← h Enter expand, collapse · Tab pane · q quit[/]", tree.selected + 1, rows.count(model), status))
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

// What the hex pane highlights for the selected row of tree: its bytes,
// shaded around them those of the row it is under, or for a value read
// from decompressed bytes, those in the file it came from, with a note;
// and for the status line, its offset and size, in temp memory.
highlight :: proc(model: ^rows.Model, tree: ^outline.State) -> (h: hexdump.Highlight, status: string) {
	row, ok := outline.selected_row(tree)
	if !ok || !row.has_span do return
	if row.decompressed {
		h.value = {row.source.offset, row.source.size}
		h.has_value = true
		h.note = fmt.tprintf("at 0x%X in decompressed bytes, from those highlighted", row.span.offset)
		return h, fmt.tprintf(" · 0x%X, %s, decompressed", row.span.offset, byte_count(row.span.size))
	}
	h.value = {row.span.offset, row.span.size}
	h.has_value = true
	if p := rows.parent(model, tree.selected); p >= 0 {
		if found := rows.rows(model, p, 1, preview = 1); len(found) > 0 && found[0].has_span && !found[0].decompressed {
			h.outer = {found[0].span.offset, found[0].span.size}
			h.has_outer = true
		}
	}
	return h, fmt.tprintf(" · 0x%X, %s", row.span.offset, byte_count(row.span.size))
}

// "1 byte", or "n bytes", in temp memory.
byte_count :: proc(n: int) -> string {
	return n == 1 ? "1 byte" : fmt.tprintf("%d bytes", n)
}
