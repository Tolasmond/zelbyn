package tests

import fld "../gnrcrdr/field"
import ksy "../gnrcrdr/ksy"
import mdat "../gnrcrdr/metadata"
import rdr "../gnrcrdr/reader"
import sql "../gnrcrdr/sqlite"
import "base:intrinsics"
import "core:reflect"
import "core:testing"

DB_PATH :: "data/Gif89aMetadata.sqlite3"

// The SQLite GIF schema ported to .ksy (step 5); it gives the same dumps.
KSY_PATH :: "formats/gif89a.ksy"

// The front ends that compile a GIF89a schema.
Schema_Source :: enum {
	SQLite,
	Ksy,
}

// Loads the GIF89a format (id 1). Fails the test and returns false on error.
load_gif :: proc(t: ^testing.T, ff: ^mdat.File_Format) -> bool {
	err := sql.read_file_format(DB_PATH, 1, ff)
	defer sql.destroy_load_error(&err)
	return testing.expectf(t, err.kind == .None, "loading format: %v (%v, table %s): %s", err.kind, err.code, err.table, err.message)
}

// Loads formats/gif89a.ksy. Fails the test and returns false on error.
load_gif_ksy :: proc(t: ^testing.T, ff: ^mdat.File_Format) -> bool {
	err := ksy.read_file_format(KSY_PATH, ff)
	defer ksy.destroy_error(&err)
	return testing.expectf(t, err.kind == .None, "loading %s: %v at %v:%v: %s", KSY_PATH, err.kind, err.line, err.column, err.message)
}

load_gif_from :: proc(t: ^testing.T, source: Schema_Source, ff: ^mdat.File_Format) -> bool {
	switch source {
	case .SQLite:
		return load_gif(t, ff)
	case .Ksy:
		return load_gif_ksy(t, ff)
	}
	return false
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

// a == b for a union that has no == (mdat.Scalar, fld.Value): the same
// variant, with equal values, comparing slices by their elements.
variant_equal :: proc(a, b: $U) -> bool where intrinsics.type_is_union(U) {
	x, y := reflect.get_union_variant(a), reflect.get_union_variant(b)
	return x.id == y.id && reflect.equal(x, y, including_indirect_array_recursion = true)
}
