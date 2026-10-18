package tests

import mdat "../gnrcrdr/metadata"
import sql "../gnrcrdr/sqlite"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:testing"

@(test)
loads_gif_format :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)

	// .None also proves close returned OK, i.e. every statement was finalized
	err := sql.read_file_format(DB_PATH, 1, &ff)
	defer sql.destroy_load_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v (%v, table %s): %s", err.kind, err.code, err.table, err.message) do return

	testing.expect_value(t, ff.name, "GIF89a")
	if testing.expect(t, ff.root != nil, "root is nil") {
		testing.expect_value(t, ff.root.id, 5000)
	}
}

// Reads the GIF89a records (format id 1) into records, allocated in arena.
// Fails the test and returns false on error.
@(private = "file")
read_gif_records :: proc(t: ^testing.T, records: ^sql.Records, arena: ^virtual.Arena) -> bool {
	err := sql.read_records(DB_PATH, 1, records, virtual.arena_allocator(arena))
	defer sql.destroy_load_error(&err)
	return testing.expectf(t, err.kind == .None, "reading records: %v (%v, table %s): %s", err.kind, err.code, err.table, err.message)
}

@(test)
packed_ranges :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	records: sql.Records
	if !read_gif_records(t, &records, &arena) do return

	Expect :: struct {
		owner: int,
		count: int,
	}
	for e in ([]Expect{{5010, 4}, {5023, 3}, {5060, 4}}) {
		n := 0
		for p in records.packed_records {
			if p.id == e.owner do n += 1
		}
		testing.expectf(t, n == e.count, "%v: %v packed fields, want %v", e.owner, n, e.count)
	}

	field_ids := make([dynamic]int, context.temp_allocator)
	for p in records.packed_records {
		if p.id == 5010 do append(&field_ids, p.field_id)
	}
	slice.sort(field_ids[:])
	testing.expectf(t, slice.equal(field_ids[:], []int{5006, 5007, 5008, 5009}), "5010 field ids = %v", field_ids)
}

@(test)
flag_shift_loaded :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	records: sql.Records
	if !read_gif_records(t, &records, &arena) do return

	for id in ([]int{5, 6}) {
		rec := records.set_length_map[id]
		if !testing.expectf(t, rec != nil, "no Length record %v", id) do continue
		shift, has_shift := rec.flag_shift.?
		testing.expectf(t, has_shift && shift == 7, "Length %v: flag_shift = %v, want 7", id, rec.flag_shift)
		mask, has_mask := rec.flag_mask.?
		testing.expectf(t, has_mask && mask == 128, "Length %v: flag_mask = %v, want 128", id, rec.flag_mask)
	}
}

@(test)
format_filtered_counts :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	records: sql.Records
	if !read_gif_records(t, &records, &arena) do return

	testing.expect_value(t, len(records.set_helper_map), 14)

	total := 0
	for _, rows in records.parent_map {
		total += len(rows)
	}
	testing.expect_value(t, total, 74)
}

@(test)
unknown_format :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	err := sql.read_file_format(DB_PATH, 999, &ff)
	testing.expect_value(t, err.kind, sql.Load_Error_Kind.Format_Not_Found)
	sql.destroy_load_error(&err)
	mdat.destroy_file_format(&ff)
}

@(test)
missing_database :: proc(t: ^testing.T) {
	path :: "data/does_not_exist.sqlite3"

	ff: mdat.File_Format
	err := sql.read_file_format(path, 1, &ff)
	testing.expect_value(t, err.kind, sql.Load_Error_Kind.Open_Failed)
	testing.expect(t, !os.exists(path), "read_file_format created the missing database file")
	sql.destroy_load_error(&err)
	mdat.destroy_file_format(&ff)
}
