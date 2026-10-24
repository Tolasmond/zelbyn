// One cold measurement of zelbyn: in a fresh process, compiles a schema
// from its file, reads the input, decodes it and writes the JSON dump to
// memory, once each, and prints how long each phase took. bench.py builds it
// and runs it in a new process for every measurement; run that rather than
// this.
//
//     bench_oneshot <schema.ksy> <file> [--spans]
//     bench_oneshot --start-only
//
// Prints one line of name=value pairs: compile_us, read_us, decode_us and
// json_us; faults, the page faults taken during the decode (-1 where the
// platform cannot count them); tree_bytes, the bytes the tree's arena handed
// out, which do not include the input; and input_bytes. With --spans the
// tree records the span of each value. With --start-only it exits at once,
// so that bench.py can time starting a process.
package bench

import arn "../../zelbyn/arena"
import dmp "../../zelbyn/dump"
import fld "../../zelbyn/field"
import ksy "../../zelbyn/ksy"
import mdata "../../zelbyn/metadata"
import rdr "../../zelbyn/reader"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--start-only" do return
	spans := len(os.args) == 4 && os.args[3] == "--spans"
	if len(os.args) != 3 && !spans {
		fmt.eprintln("usage: bench_oneshot <schema.ksy> <file> [--spans] | --start-only")
		os.exit(2)
	}
	schema, path := os.args[1], os.args[2]

	t := time.tick_now()
	ff: mdata.File_Format
	if err := ksy.read_file_format(schema, &ff); err.kind != .None {
		fmt.eprintfln("%s:%v:%v: %v: %s", schema, err.line, err.column, err.kind, err.message)
		os.exit(1)
	}
	compile := time.tick_lap_time(&t)

	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", path, read_err)
		os.exit(1)
	}
	read := time.tick_lap_time(&t)

	faults_before := page_faults()
	tree: fld.Value_Tree
	_, err := rdr.read_from_bytes(data, &ff, &tree, spans)
	decode := time.tick_lap_time(&t)
	faults := page_faults()
	if err.kind != .None {
		fmt.eprintfln("%s: %v at 0x%08X in %s", path, err.kind, err.offset, err.path)
		os.exit(1)
	}
	if faults_before >= 0 && faults >= 0 {
		faults -= faults_before
	} else {
		faults = -1
	}

	out := strings.builder_make()
	_ = time.tick_lap_time(&t)
	if werr := dmp.write_json(strings.to_writer(&out), &ff, &tree); werr != .None {
		fmt.eprintfln("%s: writing JSON: %v", path, werr)
		os.exit(1)
	}
	json := time.tick_lap_time(&t)

	tree_bytes := arn.arena_used(&tree.arena)

	fmt.printfln(
		"compile_us=%.1f read_us=%.1f decode_us=%.1f json_us=%.1f faults=%v tree_bytes=%v input_bytes=%v",
		time.duration_microseconds(compile),
		time.duration_microseconds(read),
		time.duration_microseconds(decode),
		time.duration_microseconds(json),
		faults,
		tree_bytes,
		len(data),
	)
}
