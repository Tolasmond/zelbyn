package tests

import dat "../gnrcrdr/data"
import fld "../gnrcrdr/field"
import ksy "../gnrcrdr/ksy"
import mdat "../gnrcrdr/metadata"
import "core:log"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"

@(test)
decode_uses_only_arena :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	for s in ([]Sample{SAMPLE_855, SAMPLE_CG89A}) {
		data, read_err := os.read_entire_file(s.path, context.allocator)
		if !testing.expectf(t, read_err == nil, "reading %s: %v", s.path, read_err) do continue
		defer delete(data)

		d: Decoded
		defer destroy_decoded(&d)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			context.logger = log.nil_logger()
			decode_bytes(&ff, data, &d)
		}

		testing.expectf(t, d.err.kind == .None, "%s: %v at 0x%08X in %s", s.path, d.err.kind, d.err.offset, d.err.path)
		testing.expectf(t, d.consumed == s.consumed, "%s: consumed %v, want %v", s.path, d.consumed, s.consumed)
		testing.expectf(t, track.total_allocation_count == 0, "%s: %v heap allocations, want 0", s.path, track.total_allocation_count)
		testing.expectf(t, d.tree.arena.block != nil && d.tree.arena.block.used > 0, "%s: arena unused", s.path)
	}
}

@(test)
read_allocates_only_file_buffer :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d: Decoded
	defer destroy_decoded(&d)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		decode_file(&ff, SAMPLE_855.path, &d)
	}

	testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, track.current_memory_allocated, 0)
	testing.expect_value(t, track.total_allocation_count, 1) // the file buffer, already freed
}

@(test)
decode_error_allocates_only_path :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	text := "hello world, not a gif at all"

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
		path_ok = d.err.path == "GIF89a[0].Signature[0]"
		live_with_error = len(track.allocation_map)
		destroy_decoded(&d)

		md: Decoded
		decode_file(&ff, "data/does_not_exist.gif", &md)
		missing_kind = md.err.kind
		destroy_decoded(&md)
	}

	testing.expect_value(t, kind, .Not_Equal)
	testing.expect(t, path_ok, "path should be \"GIF89a[0].Signature[0]\"")
	testing.expect_value(t, live_with_error, 1) // only Parse_Error.path
	testing.expect_value(t, missing_kind, .File_Read_Failed)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
value_tree_outlives_schema_and_input :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	if !load_gif(t, &ff) {
		mdat.destroy_file_format(&ff)
		return
	}

	data := with_header({0x21, 0xFE, 0x03, 'a', 'b', 'c', 0x00, 0x3B})

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

	// the slots of the fields looked at below, found while the schema exists
	signature, version, blocks := slot_by_name(ff.root, "signature"), slot_by_name(ff.root, "version"), slot_by_name(ff.root, "blocks")
	path := [?]string{"blocks", "extensions", "comment_extension", "comment_data", "data_sub_block_values"}
	slots: [len(path)]int
	set := ff.root
	for name, i in path {
		slots[i] = slot_by_name(set, name)
		if i + 1 < len(path) do set = set.children[child_index(set, name)]
	}

	// clobber and free the input and the schema before looking at the tree
	for &b in data do b = 0xAA
	delete(data)
	mdat.destroy_file_format(&ff)

	testing.expect_value(t, track.total_allocation_count, 0)
	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return

	g := d.tree.root[0].(^fld.Instance)
	testing.expect_value(t, g.slots[signature][0].(string), "GIF")
	testing.expect_value(t, g.slots[version][0].(string), "89a")

	if !testing.expect_value(t, len(g.slots[blocks]), 1) do return
	instance := g
	for slot in slots[:len(slots) - 1] {
		instance = instance.slots[slot][0].(^fld.Instance)
	}
	blob := instance.slots[slots[len(slots) - 1]][0].([]byte)
	testing.expect_value(t, string(blob), "abc")
}

// The index in set's children of the child whose .ksy id is name.
@(private = "file")
child_index :: proc(set: ^mdat.Node, name: string) -> int {
	for child, i in set.children {
		if child.ref_name == name do return i
	}
	panic("child_index: no such child")
}

// The slot in an instance of set of the child whose .ksy id is name.
@(private = "file")
slot_by_name :: proc(set: ^mdat.Node, name: string) -> int {
	return mdat.slot_of(set, child_index(set, name))
}

@(test)
value_tree_reuse_after_destroy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x3B})
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
	testing.expect_value(t, second_consumed, 14)
}

@(test)
schema_compile_uses_only_arena :: proc(t: ^testing.T) {
	for path in ([?]string{KSY_PATH, GIF_KSY_PATH}) {
		src, read_err := os.read_entire_file(path, context.allocator)
		if !testing.expectf(t, read_err == nil, "reading %s: %v", path, read_err) do continue
		defer delete(src)

		ff: mdat.File_Format
		defer mdat.destroy_file_format(&ff)

		err: ksy.Error
		defer ksy.destroy_error(&err)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			context.logger = log.nil_logger()
			err = ksy.compile(string(src), &ff)
		}

		testing.expectf(t, err.kind == .None, "%s: %v at %v:%v: %s", path, err.kind, err.line, err.column, err.message)
		testing.expectf(t, track.total_allocation_count == 0, "%s: %v heap allocations, want 0", path, track.total_allocation_count)
		testing.expectf(t, ff.arena.total_used > 0, "%s: arena unused", path)
	}
}

@(test)
schema_error_allocates_only_message :: proc(t: ^testing.T) {
	Case :: struct {
		path: string, // read with read_file_format; when empty, src is compiled
		src:  string,
		kind: ksy.Error_Kind,
		live: int, // allocations left with the error: the message, if it has one
	}

	for c in ([]Case{{"", "meta:\n  id: [\n", .Syntax, 1}, {"", "meta:\n  id: x\nseq:\n  - id: a\n    type: nope\n", .Invalid, 1}, {"formats/does_not_exist.ksy", "", .Read_Failed, 0}}) {
		ff: mdat.File_Format

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
			mdat.destroy_file_format(&ff)
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
	ff: mdat.File_Format

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()
		mdat.destroy_file_format(&ff) // never loaded
	}

	if !load_gif(t, &ff) {
		mdat.destroy_file_format(&ff)
		return
	}

	arena_reset, name_reset, root_reset: bool
	{
		context.allocator = mem.tracking_allocator(&track)
		context.logger = log.nil_logger()

		mdat.destroy_file_format(&ff)
		arena_reset = ff.arena.curr_block == nil
		name_reset = ff.name == ""
		root_reset = ff.root == nil

		mdat.destroy_file_format(&ff) // already destroyed: must not crash
	}

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect(t, arena_reset, "ff.arena.curr_block should be nil")
	testing.expect(t, name_reset, "ff.name should be empty")
	testing.expect(t, root_reset, "ff.root should be nil")
}
