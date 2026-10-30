// zelbyn-view: a viewer of a file decoded with a schema, in the terminal.
// It runs on Linux only, as hnoss, the library it draws with (a submodule
// in view/hnoss), does. So far it lists the fields of the top-level type.
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

	tree: fld.Value_Tree
	// the tree may be partially filled after a parse error; free it either way
	defer fld.destroy_value_tree(&tree)
	_, parse_err := rdr.read(file_path, &file_format, &tree, spans = true)
	defer rdr.destroy_parse_error(&parse_err)
	if parse_err.kind != .None {
		cli.write_parse_error(stderr, file_path, parse_err)
		return 1
	}

	rows := field_rows(&file_format, &tree)
	defer {
		for row in rows do delete(row)
		delete(rows)
	}

	// show has given the terminal back by now, so the message is seen
	if err := show(file_path, rows); err != .None {
		fmt.eprintfln("error: terminal: %v", err)
		return 1
	}
	return 0
}

// One row for each field of the top-level type of tree, each followed by
// its bit fields, then each parse instance, as the text dump orders them,
// with the number of values each has.
field_rows :: proc(format: ^mdata.File_Format, tree: ^fld.Value_Tree) -> []string {
	rows := make([dynamic]string)
	if len(tree.root) == 0 do return rows[:]
	instance, is_instance := tree.root[0].(^fld.Instance)
	if !is_instance do return rows[:]

	add :: proc(rows: ^[dynamic]string, name: string, values: []fld.Value) {
		append(rows, fmt.aprintf("%s (%d)", name, len(values)))
	}
	set := mdata.instance_set(format.root, instance)
	slot := len(set.parse_instances)
	for child in set.children {
		add(&rows, child.name, instance.slots[slot])
		for bit, b in child.bits do add(&rows, bit.name, instance.slots[slot + 1 + b])
		slot += 1 + len(child.bits)
	}
	for p, j in set.parse_instances do add(&rows, p.name, instance.slots[j])
	return rows[:]
}

// Takes the terminal and shows rows in a list, titled with file_path,
// until q, Esc or Ctrl+C, then gives the terminal back.
show :: proc(file_path: string, rows: []string) -> hnoss.Error {
	context.assertion_failure_proc = hnoss.assertion_failure_proc
	term := hnoss.init() or_return
	defer hnoss.deinit(&term)

	// the title is markup, in which [[ is a literal [
	title, _ := strings.replace_all(filepath.base(file_path), "[", "[[", context.temp_allocator)
	list: hnoss.List_State
	events: []hnoss.Event
	loop: for {
		f := hnoss.begin_frame(&term)
		ui := hnoss.ui(f, events)
		area := f.area
		footer := hnoss.cut_bottom(&area, 1)
		hnoss.label(ui, footer, "[dim]↑↓ jk PgUp PgDn Home End · q quit[/]")
		hnoss.focus(ui, &list)
		inner := hnoss.box(ui, area, title, {focused = true})
		hnoss.list(ui, inner, rows, &list, {scrollbar = true})
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
