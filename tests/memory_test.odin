package tests

import arn "../zelbyn/arena"
import dat "../zelbyn/data"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// With spans or without, a small tree and a large one.
@(test)
decode_uses_only_arena :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	for records in ([?]int{4, 20000}) do for spans in ([?]bool{false, true}) {
		data := sample_input(records)
		defer delete(data)

		d: Decoded
		defer destroy_decoded(&d)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			context.logger = log.nil_logger()
			decode_bytes(&ff, data[:], &d, spans)
		}

		testing.expectf(t, d.err.kind == .None, "%v records: %v at 0x%08X in %s", records, d.err.kind, d.err.offset, d.err.path)
		testing.expectf(t, d.consumed == len(data), "%v records: consumed %v, want %v", records, d.consumed, len(data))
		testing.expectf(t, track.total_allocation_count == 0, "%v records, spans %v: %v heap allocations, want 0", records, spans, track.total_allocation_count)
		testing.expectf(t, d.tree.arena.block != nil && d.tree.arena.block.used > 0, "%v records: arena unused", records)
	}
}

// zlib decompresses process: zlib into the tree's arena, with what it
// allocates while it does.
@(test)
decode_zlib_uses_only_arena :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile("meta:\n  id: z\nseq:\n  - id: n\n    type: u1\n  - id: z\n    size: n\n    process: zlib\n", &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %s", err.message) do return

	// "hello world", compressed
	input := []byte{19, 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x1a, 0x0b, 0x04, 0x5d}
	d: Decoded
	defer destroy_decoded(&d)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		decode_bytes(&ff, input, &d)
	}

	testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path)
	testing.expect_value(t, track.total_allocation_count, 0)
}

// read puts the file in the tree's arena, so it allocates nothing else.
@(test)
read_uses_only_arena :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	data := sample_input(20000)
	size := len(data)
	path, ok := write_temp_file(t, data[:])
	delete(data)
	if !ok do return
	defer delete(path)
	defer os.remove(path)

	d: Decoded
	defer destroy_decoded(&d)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		decode_file(&ff, path, &d)
	}

	testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path)
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expectf(t, d.tree.arena.block != nil && d.tree.arena.block.used > uint(size), "the arena does not hold the file")
}

@(test)
decode_error_allocates_only_its_strings :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	text := "hello world, not a sample at all"

	// recorded inside the block, asserted after it: the tracker frees the path
	kind: dat.Read_Error
	path_ok: bool
	live_with_error: int
	missing_kind: dat.Read_Error

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()

		d: Decoded
		decode_bytes(&ff, transmute([]byte)text, &d)
		kind = d.err.kind
		path_ok = d.err.path == "sample[0].magic[0]" && d.err.value == "<4 bytes> 68 65 6c 6c" && d.err.expected == "<4 bytes> 53 4d 50 4c"
		live_with_error = len(track.allocation_map)
		destroy_decoded(&d)

		md: Decoded
		decode_file(&ff, "tests/does_not_exist.bin", &md)
		missing_kind = md.err.kind
		destroy_decoded(&md)
	}

	testing.expect_value(t, kind, .Not_Equal)
	testing.expect(t, path_ok, "the error should be in sample[0].magic[0], reading 68 65 6c 6c, expecting 53 4d 50 4c")
	testing.expect_value(t, live_with_error, 3) // only Parse_Error.path, value and expected
	testing.expect_value(t, missing_kind, .File_Read_Failed)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// As decode_error_allocates_only_its_strings, from a file, with the temp
// allocator tracked too: the tests' check of the tree a failed decode
// leaves reads the file again, and must do it in an arena of its own.
@(test)
decode_file_error_allocates_only_its_strings :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	text := "hello world, not a sample at all"
	path, ok := write_temp_file(t, transmute([]byte)text)
	if !ok do return
	defer delete(path)
	defer os.remove(path)

	kind: dat.Read_Error
	live_with_error, temp_live: int
	track, temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	mem.tracking_allocator_init(&temp_track, context.allocator)
	defer mem.tracking_allocator_destroy(&temp_track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.temp_allocator = mem.tracking_allocator(&temp_track)
		context.logger = log.nil_logger()

		d: Decoded
		decode_file(&ff, path, &d)
		kind = d.err.kind
		live_with_error = len(track.allocation_map)
		temp_live = len(temp_track.allocation_map)
		destroy_decoded(&d)
	}

	testing.expect_value(t, kind, .Not_Equal)
	testing.expect_value(t, live_with_error, 3) // only Parse_Error.path, value and expected
	testing.expect_value(t, temp_live, 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// Writes data to a new temporary file and returns its path, which the
// caller deletes, and removes the file. The file is named by the test
// that makes it (see temp_file in cli_test.odin).
@(private = "file")
write_temp_file :: proc(t: ^testing.T, data: []byte, loc := #caller_location) -> (path: string, ok: bool) {
	f, create_err := os.create_temp_file("", fmt.tprintf("zelbyn_%s_*.bin", loc.procedure))
	if !testing.expectf(t, create_err == nil, "creating a temporary file: %v", create_err) do return
	path = strings.clone(os.name(f))
	_, write_err := os.write(f, data)
	os.close(f)
	if !testing.expectf(t, write_err == nil, "writing %s: %v", path, write_err) {
		_ = os.remove(path)
		delete(path)
		return "", false
	}
	return path, true
}

// The slots of the fields of sample_input(4) that check_sample_tree looks
// at, found while the schema exists.
@(private = "file")
Sample_Slots :: struct {
	name, records, body: int,
}

@(private = "file")
sample_slots :: proc(ff: ^mdata.File_Format) -> Sample_Slots {
	record := ff.root.children[child_index(ff.root, "records")]
	return {slot_by_name(ff.root, "name"), slot_by_name(ff.root, "records"), slot_by_name(record, "body")}
}

// Checks the tree of sample_input(4) without the schema; returns the raw
// body of its third record.
@(private = "file")
check_sample_tree :: proc(t: ^testing.T, d: ^Decoded, s: Sample_Slots) -> (blob: []byte) {
	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return

	root := d.tree.root[0].(^fld.Instance)
	testing.expect_value(t, root.slots[s.name][0].(string), "sample")
	if !testing.expect_value(t, len(root.slots[s.records]), 4) do return
	record := root.slots[s.records][2].(^fld.Instance)
	blob = record.slots[s.body][0].([]byte)
	testing.expect_value(t, string(blob), "\x02\x03\x04")
	return
}

// A tree from read_from_bytes needs no schema, and its blobs are views of
// the bytes it borrows.
@(test)
value_tree_outlives_schema :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	if !load_sample(t, &ff) {
		mdata.destroy_file_format(&ff)
		return
	}

	data := sample_input(4)
	defer delete(data)

	d: Decoded
	defer destroy_decoded(&d)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		decode_bytes(&ff, data[:], &d)
	}
	testing.expect_value(t, track.total_allocation_count, 0)

	slots := sample_slots(&ff)
	mdata.destroy_file_format(&ff)

	blob := check_sample_tree(t, &d, slots)
	start, end := uintptr(raw_data(data)), uintptr(raw_data(data)) + uintptr(len(data))
	testing.expect(t, len(blob) > 0 && uintptr(raw_data(blob)) >= start && uintptr(raw_data(blob)) + uintptr(len(blob)) <= end, "the blob is not a view of the input")
}

// A tree from read owns its input: it needs neither the schema nor the
// file, which is deleted before the tree is looked at.
@(test)
value_tree_from_read_outlives_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	if !load_sample(t, &ff) {
		mdata.destroy_file_format(&ff)
		return
	}

	data := sample_input(4)
	path, ok := write_temp_file(t, data[:])
	delete(data)
	if !ok {
		mdata.destroy_file_format(&ff)
		return
	}
	defer delete(path)

	d: Decoded
	defer destroy_decoded(&d)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		decode_file(&ff, path, &d)
	}
	testing.expect_value(t, track.total_allocation_count, 0)

	slots := sample_slots(&ff)
	mdata.destroy_file_format(&ff)
	remove_err := os.remove(path)
	testing.expectf(t, remove_err == nil, "removing %s: %v", path, remove_err)

	check_sample_tree(t, &d, slots)
}

// A string argument of a type's param, from a literal of the schema, part
// of one, or one reached through a value instance or an array literal.
STRING_ARGS_KSY :: `meta: {id: string_args}
seq:
  - id: literal
    type: child("hello")
  - id: part
    type: child("hello world".substring(6, 11))
  - id: through_instance
    type: child(greeting)
  - id: item
    type: child(["no", "yes"][1])
  - id: instance_item
    type: child(answers[1])
instances:
  greeting: {value: '"hi"'}
  answers: {value: '["no", "yes"]'}
types:
  child:
    params:
      - {id: text, type: str}
`

// The string arguments of params are in the tree, which needs no schema
// once decoded, rather than in the schema's literals.
@(test)
value_tree_string_args_outlive_schema :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	err := ksy.compile(STRING_ARGS_KSY, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v at %v:%v: %s", err.kind, err.line, err.column, err.message) {
		mdata.destroy_file_format(&ff)
		return
	}

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, nil, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v at %v in %s", d.err.kind, d.err.offset, d.err.path) {
		mdata.destroy_file_format(&ff)
		return
	}

	fields := [?]string{"literal", "part", "through_instance", "item", "instance_item"}
	want := [len(fields)]string{"hello", "world", "hi", "yes", "yes"}
	texts: [len(fields)]string
	in_schema := false
	root := root_instance(&ff, &d)
	for name, i in fields {
		child := field_instance(root, name)
		texts[i] = child.instance.slots[mdata.param_slot(child.set, 0)][0].(string)
		if !testing.expectf(t, !in_arena(&ff.arena, texts[i]), "%s: the argument is in the schema's arena", name) do in_schema = true
	}
	mdata.destroy_file_format(&ff)
	// reading an argument in the schema's arena would fault once it is destroyed
	if in_schema do return

	for name, i in fields {
		testing.expectf(t, texts[i] == want[i], "%s: got %q, want %q", name, texts[i], want[i])
	}
}

// Whether s is in a block of a.
@(private = "file")
in_arena :: proc(a: ^arn.Arena, s: string) -> bool {
	p := uintptr(raw_data(s))
	for b := a.block; b != nil; b = b.prev {
		if p >= uintptr(b.base) && p < uintptr(b.base) + uintptr(b.reserved) do return true
	}
	return false
}

// The index in set's children of the child whose .ksy id is name.
@(private = "file")
child_index :: proc(set: ^mdata.Node, name: string) -> int {
	for child, i in set.children {
		if child.ref_name == name do return i
	}
	panic("child_index: no such child")
}

// The slot in an instance of set of the child whose .ksy id is name.
@(private = "file")
slot_by_name :: proc(set: ^mdata.Node, name: string) -> int {
	return mdata.slot_of(set, child_index(set, name))
}

@(test)
value_tree_reuse_after_destroy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	data := sample_input(4)
	defer delete(data)

	d: Decoded
	defer destroy_decoded(&d)

	first_kind, second_kind: dat.Read_Error
	reset_ok: bool
	second_consumed: int

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()

		unused: fld.Value_Tree
		fld.destroy_value_tree(&unused)

		decode_bytes(&ff, data[:], &d)
		first_kind = d.err.kind

		fld.destroy_value_tree(&d.tree)
		fld.destroy_value_tree(&d.tree)
		reset_ok = d.tree.root == nil && d.tree.arena == {}

		decode_bytes(&ff, data[:], &d)
		second_kind = d.err.kind
		second_consumed = d.consumed
	}

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, first_kind, .None)
	testing.expect(t, reset_ok, "destroy_value_tree did not reset the tree")
	testing.expect_value(t, second_kind, .None)
	testing.expect_value(t, second_consumed, len(data))
}

@(test)
schema_compile_uses_only_arena :: proc(t: ^testing.T) {
	Schema :: struct {
		path, src: string, // path names it
	}
	for schema in ([?]Schema{{"SAMPLE_KSY", SAMPLE_KSY}, {"STRING_ARGS_KSY", STRING_ARGS_KSY}}) {
		path, src := schema.path, schema.src

		ff: mdata.File_Format
		defer mdata.destroy_file_format(&ff)

		err: ksy.Error
		defer ksy.destroy_error(&err)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			context.logger = log.nil_logger()
			err = ksy.compile(src, &ff)
		}

		testing.expectf(t, err.kind == .None, "%s: %v at %v:%v: %s", path, err.kind, err.line, err.column, err.message)
		testing.expectf(t, track.total_allocation_count == 0, "%s: %v heap allocations, want 0", path, track.total_allocation_count)
		testing.expectf(t, arn.arena_used(&ff.arena) > 0, "%s: arena unused", path)
	}
}

@(test)
schema_error_allocates_only_message_and_path :: proc(t: ^testing.T) {
	Case :: struct {
		path: string, // read with read_file_format; when empty, src is compiled
		src:  string,
		kind: ksy.Error_Kind,
		live: int, // allocations left with the error: its message and path, if it has them
	}

	cases := []Case {
		{"", "meta:\n  id: [\n", .Syntax, 1},
		{"", "meta:\n  id: x\nseq:\n  - id: a\n    type: nope\n", .Invalid, 1},
		{"formats/does_not_exist.ksy", "", .Read_Failed, 1},
		{"tests/schemas/imports/errors/broken_import.ksy", "", .Invalid, 2},
	}
	for c in cases {
		ff: mdata.File_Format

		// recorded inside the block, asserted after it: the message is freed inside
		kind: ksy.Error_Kind
		live_with_error, live_after: int

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		// collect bad frees instead of panicking, so the check below can see them
		track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		{
			context.allocator = mem.tracking_allocator(&track)
			context.logger = log.nil_logger()

			err := c.path == "" ? ksy.compile(c.src, &ff) : ksy.read_file_format(c.path, &ff)
			kind = err.kind
			live_with_error = len(track.allocation_map)
			ksy.destroy_error(&err)
			mdata.destroy_file_format(&ff)
			live_after = len(track.allocation_map)
		}

		what := c.path == "" ? c.src : c.path
		testing.expectf(t, kind == c.kind, "%q: %v, want %v", what, kind, c.kind)
		testing.expectf(t, live_with_error == c.live, "%q: %v live allocations with the error, want %v", what, live_with_error, c.live)
		testing.expectf(t, live_after == 0, "%q: %v live allocations after cleanup, want 0", what, live_after)
		testing.expectf(t, len(track.bad_free_array) == 0, "%q: %v bad frees", what, len(track.bad_free_array))
	}
}

@(test)
destroy_file_format_resets :: proc(t: ^testing.T) {
	ff: mdata.File_Format

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		mdata.destroy_file_format(&ff) // never loaded
	}

	if !load_sample(t, &ff) {
		mdata.destroy_file_format(&ff)
		return
	}

	arena_reset, name_reset, root_reset: bool
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()

		mdata.destroy_file_format(&ff)
		arena_reset = ff.arena.block == nil
		name_reset = ff.name == ""
		root_reset = ff.root == nil

		mdata.destroy_file_format(&ff) // already destroyed: must not crash
	}

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect(t, arena_reset, "ff.arena.block should be nil")
	testing.expect(t, name_reset, "ff.name should be empty")
	testing.expect(t, root_reset, "ff.root should be nil")
}
