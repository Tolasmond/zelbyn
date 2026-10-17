package tests

import mdat "../gnrcrdr/metadata"
import sql "../gnrcrdr/sqlite"
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

	testing.expect_value(t, ff.metadata.format_record.name, "GIF89a")
	testing.expect_value(t, ff.metadata.format_record.root_field, 5000)
	if testing.expect(t, ff.root_metadata_node.metadata != nil, "root metadata is nil") {
		testing.expect_value(t, ff.root_metadata_node.metadata.id, 5000)
	}
}

@(test)
packed_ranges :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	Expect :: struct {
		owner: int,
		count: int,
	}
	for e in ([]Expect{{5010, 4}, {5023, 3}, {5060, 4}}) {
		fm := ff.metadata.field_metadata_map[e.owner]
		if !testing.expectf(t, fm != nil, "no field metadata for %v", e.owner) do continue
		testing.expectf(t, len(fm.packed_fields) == e.count, "%v: %v packed fields, want %v", e.owner, len(fm.packed_fields), e.count)
		for p in fm.packed_fields {
			testing.expectf(t, p.id == e.owner, "%v: packed record has id %v", e.owner, p.id)
		}
	}

	fm := ff.metadata.field_metadata_map[5010]
	if fm == nil do return
	field_ids := make([dynamic]int, context.temp_allocator)
	for p in fm.packed_fields do append(&field_ids, p.field_id)
	slice.sort(field_ids[:])
	testing.expectf(t, slice.equal(field_ids[:], []int{5006, 5007, 5008, 5009}), "5010 field ids = %v", field_ids)
}

@(test)
flag_shift_loaded :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	for id in ([]int{5, 6}) {
		rec := ff.metadata.set_length_map[id]
		if !testing.expectf(t, rec != nil, "no Length record %v", id) do continue
		shift, has_shift := rec.flag_shift.?
		testing.expectf(t, has_shift && shift == 7, "Length %v: flag_shift = %v, want 7", id, rec.flag_shift)
		mask, has_mask := rec.flag_mask.?
		testing.expectf(t, has_mask && mask == 128, "Length %v: flag_mask = %v, want 128", id, rec.flag_mask)
	}
}

@(test)
format_filtered_counts :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	testing.expect_value(t, len(ff.metadata.set_helper_map), 14)

	total := 0
	for _, records in ff.metadata.parent_map {
		total += len(records)
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
