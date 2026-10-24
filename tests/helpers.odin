package tests

import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "base:intrinsics"
import "core:fmt"
import "core:reflect"
import "core:testing"

// A schema with the shapes the decoder's tests need, none of them from a
// real format: contents, a strz, a repeat-expr and a repeat-eos of user
// types, an enum, a switch-on type of a sized field, with raw bytes where
// no case matches, bit fields, a size-eos string and bytes, and a parse
// instance. sample_input makes its inputs.
SAMPLE_KSY :: `meta:
  id: sample
  endian: le
  encoding: ASCII
seq:
  - id: magic
    contents: SMPL
  - id: name
    type: strz
  - id: num_colors
    type: u1
  - id: colors
    type: color
    repeat: expr
    repeat-expr: num_colors
  - id: records
    type: record
    repeat: eos
instances:
  last:
    pos: _io.size - 1
    type: u1
types:
  color:
    seq:
      - id: r
        type: u1
      - id: g
        type: u1
      - id: b
        type: u1
  record:
    seq:
      - id: kind
        type: u1
        enum: kind
      - id: len
        type: u1
      - id: body
        size: len
        type:
          switch-on: kind
          cases:
            'kind::text': text_body
            'kind::flags': flags_body
  text_body:
    seq:
      - id: text
        type: str
        size-eos: true
  flags_body:
    seq:
      - id: hi
        type: b3
      - id: lo
        type: b5
      - id: rest
        size-eos: true
enums:
  kind:
    1: text
    2: flags
`

// Compiles SAMPLE_KSY. Fails the test and returns false on error.
load_sample :: proc(t: ^testing.T, ff: ^mdata.File_Format) -> bool {
	err := ksy.compile(SAMPLE_KSY, ff)
	defer ksy.destroy_error(&err)
	return testing.expectf(t, err.kind == .None, "compiling SAMPLE_KSY: %v at %v:%v: %s", err.kind, err.line, err.column, err.message)
}

// An input of SAMPLE_KSY with n records, which take turns: a text, flags,
// and a kind with no case, of 1 to 5 raw bytes. The caller deletes it.
sample_input :: proc(n: int) -> [dynamic]byte {
	data: [dynamic]byte
	append(&data, "SMPL")
	append(&data, "sample\x00")
	append(&data, 3, 255, 0, 0, 0, 255, 0, 0, 0, 255)
	for i in 0 ..< n {
		switch i % 3 {
		case 0:
			buf: [32]byte
			text := fmt.bprintf(buf[:], "record %v", i)
			append(&data, 1, byte(len(text)))
			append(&data, text)
		case 1:
			append(&data, 2, 3, byte(i), 0xab, 0xcd)
		case 2:
			m := i % 5 + 1
			append(&data, 7, byte(m))
			for k in 0 ..< m do append(&data, byte(i + k))
		}
	}
	return data
}

Decoded :: struct {
	tree:     fld.Value_Tree,
	consumed: int,
	err:      rdr.Parse_Error,
}

// d must be zero or destroyed. Decoded embeds a Value_Tree, and so its
// arena, whose blocks a copy would share without knowing of those the
// other adds, so it is filled in place and never returned by value
// (doc/arch.md, "Memory and ownership").
decode_bytes :: proc(ff: ^mdata.File_Format, data: []byte, d: ^Decoded, spans := false, args: []fld.Value = nil) {
	d.consumed, d.err = rdr.read_from_bytes(data, ff, &d.tree, spans, args)
}

decode_file :: proc(ff: ^mdata.File_Format, path: string, d: ^Decoded, spans := false) {
	d.consumed, d.err = rdr.read(path, ff, &d.tree, spans)
}

destroy_decoded :: proc(d: ^Decoded) {
	fld.destroy_value_tree(&d.tree)
	rdr.destroy_parse_error(&d.err)
}

// A decoded set instance and the set it was read as, so that tests can
// look its fields up by name.
Set_Instance :: struct {
	instance: ^fld.Instance,
	set:      ^mdata.Node,
}

// v, an instance of the set field node.
instance_of :: proc(v: fld.Value, node: ^mdata.Node) -> Set_Instance {
	instance := v.(^fld.Instance)
	return {instance, mdata.instance_set(node, instance)}
}

// The root instance of a decoded tree.
root_instance :: proc(ff: ^mdata.File_Format, d: ^Decoded) -> Set_Instance {
	return instance_of(d.tree.root[0], ff.root)
}

// The values of a field of s: a parse instance or a field by its .ksy id,
// or a bit field by its name. nil when the set has none.
field_values :: proc(s: Set_Instance, name: string) -> []fld.Value {
	k := field_slot(s, name)
	return k < 0 ? nil : s.instance.slots[k][:]
}

// The slot of a field of s, found as field_values finds it; -1 when the
// set has none.
field_slot :: proc(s: Set_Instance, name: string) -> int {
	for p, k in s.set.parse_instances {
		if p.ref_name == name do return k
	}
	slot := len(s.set.parse_instances)
	for child in s.set.children {
		if child.ref_name == name do return slot
		for bit, b in child.bits {
			if bit.name == name do return slot + 1 + b
		}
		slot += 1 + len(child.bits)
	}
	return -1
}

// Instance index of a set field of s, by .ksy id.
field_instance :: proc(s: Set_Instance, name: string, index := 0) -> Set_Instance {
	for child in s.set.children {
		if child.ref_name == name do return instance_of(field_values(s, name)[index], child)
	}
	panic("field_instance: no such set field")
}

// a == b for a union that has no == (mdata.Scalar, fld.Value): the same
// variant, with equal values, comparing slices by their elements.
variant_equal :: proc(a, b: $U) -> bool where intrinsics.type_is_union(U) {
	x, y := reflect.get_union_variant(a), reflect.get_union_variant(b)
	return x.id == y.id && reflect.equal(x, y, including_indirect_array_recursion = true)
}
