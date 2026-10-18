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

// gif.ksy from kaitai_struct_formats, unchanged (step 6).
GIF_KSY_PATH :: "formats/gif.ksy"

// The GIF schemas: the SQLite one and its .ksy port, which give the same
// dumps, and gif.ksy.
Schema_Source :: enum {
	SQLite,
	Ported,
	Kaitai,
}

// Loads the GIF89a format (id 1). Fails the test and returns false on error.
load_gif :: proc(t: ^testing.T, ff: ^mdat.File_Format) -> bool {
	err := sql.read_file_format(DB_PATH, 1, ff)
	defer sql.destroy_load_error(&err)
	return testing.expectf(t, err.kind == .None, "loading format: %v (%v, table %s): %s", err.kind, err.code, err.table, err.message)
}

// Loads the .ksy schema at path. Fails the test and returns false on error.
load_ksy :: proc(t: ^testing.T, path: string, ff: ^mdat.File_Format) -> bool {
	err := ksy.read_file_format(path, ff)
	defer ksy.destroy_error(&err)
	return testing.expectf(t, err.kind == .None, "loading %s: %v at %v:%v: %s", path, err.kind, err.line, err.column, err.message)
}

load_gif_from :: proc(t: ^testing.T, source: Schema_Source, ff: ^mdat.File_Format) -> bool {
	switch source {
	case .SQLite:
		return load_gif(t, ff)
	case .Ported:
		return load_ksy(t, KSY_PATH, ff)
	case .Kaitai:
		return load_ksy(t, GIF_KSY_PATH, ff)
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

// A decoded set instance and the set it was read as, so that tests can
// look its fields up by node id.
Set_Instance :: struct {
	instance: ^fld.Instance,
	set:      ^mdat.Node,
}

// v, an instance of the set field node.
instance_of :: proc(v: fld.Value, node: ^mdat.Node) -> Set_Instance {
	instance := v.(^fld.Instance)
	return {instance, mdat.instance_set(node, instance)}
}

// The root instance of a decoded tree.
root_instance :: proc(ff: ^mdat.File_Format, d: ^Decoded) -> Set_Instance {
	return instance_of(d.tree.root[0], ff.root)
}

// The values of the field or bit field of s whose node id is id; nil when
// the set has none.
field_values :: proc(s: Set_Instance, id: int) -> []fld.Value {
	slot := 0
	for child in s.set.children {
		if child.id == id do return s.instance.slots[slot][:]
		for bit, b in child.bits {
			if bit.id == id do return s.instance.slots[slot + 1 + b][:]
		}
		slot += 1 + len(child.bits)
	}
	return nil
}

// Instance index of the set field of s whose node id is id.
field_instance :: proc(s: Set_Instance, id: int, index := 0) -> Set_Instance {
	for child in s.set.children {
		if child.id == id do return instance_of(field_values(s, id)[index], child)
	}
	panic("field_instance: no such set field")
}

// a == b for a union that has no == (mdat.Scalar, fld.Value): the same
// variant, with equal values, comparing slices by their elements.
variant_equal :: proc(a, b: $U) -> bool where intrinsics.type_is_union(U) {
	x, y := reflect.get_union_variant(a), reflect.get_union_variant(b)
	return x.id == y.id && reflect.equal(x, y, including_indirect_array_recursion = true)
}
