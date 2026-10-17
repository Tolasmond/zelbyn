package tests

import fld "../gnrcrdr/field"
import mdat "../gnrcrdr/metadata"
import rdr "../gnrcrdr/reader"
import sql "../gnrcrdr/sqlite"
import "core:testing"

DB_PATH :: "data/Gif89aMetadata.sqlite3"

// Loads the GIF89a format (id 1). Fails the test and returns false on error.
load_gif :: proc(t: ^testing.T, ff: ^mdat.File_Format) -> bool {
	err := sql.read_file_format(DB_PATH, 1, ff)
	defer sql.destroy_load_error(&err)
	return testing.expectf(t, err.kind == .None, "loading format: %v (%v, table %s): %s", err.kind, err.code, err.table, err.message)
}

Decoded :: struct {
	tree:     fld.Value_Tree,
	consumed: int,
	err:      rdr.Parse_Error,
}

// d must be zero or destroyed. Decoded embeds an arena, so it is filled in
// place and never returned by value (see §3.3).
decode_bytes :: proc(ff: ^mdat.File_Format, data: []byte, d: ^Decoded) {
	d.consumed, d.err = rdr.read_from_bytes(data, ff, &d.tree)
}

decode_file :: proc(ff: ^mdat.File_Format, path: string, d: ^Decoded) {
	d.consumed, d.err = rdr.read(path, ff, &d.tree)
}

destroy_decoded :: proc(d: ^Decoded) {
	fld.destroy_value_tree(&d.tree)
	rdr.destroy_parse_error(&d.err)
}

set_of :: proc(v: fld.Value) -> map[int][dynamic]fld.Value {
	return v.(map[int][dynamic]fld.Value)
}
