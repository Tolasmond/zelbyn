// Measures gnrcrdr in process (decision record §9.4): for each sample,
// the tree size and the median time to decode, and to decode and write the
// JSON dump. Build with -o:speed and run from the repository root:
//
//     odin run tools/bench -o:speed [-- <schema.ksy>]
//
// The schema defaults to formats/gif.ksy. Each measurement runs for at
// least a second and 20 times, after 3 warm-up runs.
package bench

import dmp "../../gnrcrdr/dump"
import fld "../../gnrcrdr/field"
import ksy "../../gnrcrdr/ksy"
import mdat "../../gnrcrdr/metadata"
import rdr "../../gnrcrdr/reader"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

SAMPLES :: [?]string{"data/855.gif", "data/89AILLUS.GIF", "data/BOB_89A.GIF", "data/CG89A.GIF", "data/STIGR9.GIF", "data/TEXTTST.GIF"}

Bench :: struct {
	src:  string,
	ff:   ^mdat.File_Format,
	data: []byte,
	out:  ^strings.Builder,
}

// The median run of f, in microseconds.
measure :: proc(f: proc(b: ^Bench), b: ^Bench) -> f64 {
	for _ in 0 ..< 3 do f(b)
	times := make([dynamic]f64)
	defer delete(times)
	total: time.Duration
	for len(times) < 20 || total < time.Second {
		start := time.tick_now()
		f(b)
		d := time.tick_since(start)
		total += d
		append(&times, time.duration_microseconds(d))
	}
	slice.sort(times[:])
	return times[len(times) / 2]
}

compile_schema :: proc(b: ^Bench) {
	ff: mdat.File_Format
	err := ksy.compile(b.src, &ff)
	assert(err.kind == .None)
	mdat.destroy_file_format(&ff)
}

decode :: proc(b: ^Bench) {
	tree: fld.Value_Tree
	_, err := rdr.read_from_bytes(b.data, b.ff, &tree)
	assert(err.kind == .None)
	fld.destroy_value_tree(&tree)
}

decode_json :: proc(b: ^Bench) {
	tree: fld.Value_Tree
	_, err := rdr.read_from_bytes(b.data, b.ff, &tree)
	assert(err.kind == .None)
	strings.builder_reset(b.out)
	werr := dmp.write_json(strings.to_writer(b.out), b.ff, &tree)
	assert(werr == .None)
	fld.destroy_value_tree(&tree)
}

// The bytes the tree's arena has handed out.
tree_size :: proc(b: ^Bench) -> uint {
	tree: fld.Value_Tree
	defer fld.destroy_value_tree(&tree)
	_, err := rdr.read_from_bytes(b.data, b.ff, &tree)
	assert(err.kind == .None)
	used: uint
	for block := tree.arena.block; block != nil; block = block.prev do used += block.used
	return used
}

main :: proc() {
	schema := len(os.args) > 1 ? os.args[1] : "formats/gif.ksy"
	src, read_err := os.read_entire_file(schema, context.allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", schema, read_err)
		os.exit(1)
	}
	ff: mdat.File_Format
	if err := ksy.compile(string(src), &ff); err.kind != .None {
		fmt.eprintfln("%s:%v:%v: %v: %s", schema, err.line, err.column, err.kind, err.message)
		os.exit(1)
	}
	out := strings.builder_make()
	b := Bench{src = string(src), ff = &ff, out = &out}

	fmt.printfln("schema %s: compile %.1f µs", schema, measure(compile_schema, &b))
	fmt.printfln("%-18s %10s %10s %12s %16s", "file", "input KB", "tree KB", "decode µs", "decode+json µs")
	for path in SAMPLES {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("cannot read %s: %v", path, err)
			os.exit(1)
		}
		b.data = data
		fmt.printfln("%-18s %10s %10s %12s %16s", path, one_place(f64(len(data)) / 1024), one_place(f64(tree_size(&b)) / 1024), one_place(measure(decode, &b)), one_place(measure(decode_json, &b)))
		delete(data)
	}
}

// f with one decimal, in context.temp_allocator; fmt pads floats with zeros
one_place :: proc(f: f64) -> string {
	return fmt.tprintf("%.1f", f)
}
