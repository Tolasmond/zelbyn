package tests

import "../zelbyn/codegen"
import dmp "../zelbyn/dump"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import rdr "../zelbyn/reader"
import "base:intrinsics"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:sync"
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
	when CODEGEN_RECORD != "" do record_decode(ff, data, d, args)
}

decode_file :: proc(ff: ^mdata.File_Format, path: string, d: ^Decoded, spans := false) {
	d.consumed, d.err = rdr.read(path, ff, &d.tree, spans)
	when CODEGEN_RECORD != "" {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil do record_decode(ff, data, d, nil)
	}
}

// A directory that every decode of decode_bytes and decode_file is
// recorded in, for tools/codegen_tests/check.py, which decodes each input
// again with the code generated from its plan and compares the results:
// -define:ZELBYN_CODEGEN_RECORD=<dir>. "" records nothing.
CODEGEN_RECORD :: #config(ZELBYN_CODEGEN_RECORD, "")

@(private = "file")
record_lock: sync.Mutex
@(private = "file")
record_count: int

// Records the decode of data with ff, whose result d has: the package
// generated from the plan, once in <dir>/<hash of the code>/pkg, and in
// that directory's cases, the input, the arguments as an Odin literal of
// the package's Args, and the result, as the program check.py builds writes
// it. A decode that reaches one of the decoder's limits, which generated
// code does not have, or whose arguments are not of their params' types, is
// not recorded; nor is one whose plan the generator cannot write code for,
// which is listed in <dir>/not_generated.txt.
@(private = "file")
record_decode :: proc(ff: ^mdata.File_Format, data: []byte, d: ^Decoded, args: []fld.Value) {
	#partial switch d.err.kind {
	case .Too_Deep, .Memory_Limit, .Step_Limit, .File_Read_Failed, .Invalid_Arguments:
		return
	}
	sync.mutex_lock(&record_lock)
	defer sync.mutex_unlock(&record_lock)
	// none of it in the test's allocators, which the memory tests check
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do panic("recording: no memory")
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator

	code, err := codegen.generate(ff, {package_name = "pkg", runtime = "zelbyn:data"}, context.temp_allocator)
	if err.message != "" {
		path := fmt.tprintf("%s/not_generated.txt", CODEGEN_RECORD)
		line := fmt.tprintf("%s: %s\n", ff.name, err.message)
		f, open_err := os.open(path, {.Write, .Create, .Append})
		if open_err == nil {
			_, _ = os.write_string(f, line)
			_ = os.close(f)
		}
		delete(err.message)
		return
	}
	dir := fmt.tprintf("%s/%016x", CODEGEN_RECORD, hash.fnv64a(transmute([]byte)code))
	pkg := fmt.tprintf("%s/pkg", dir)
	if !os.exists(pkg) {
		if e := os.make_directory_all(fmt.tprintf("%s/cases", dir)); e != nil do panic(fmt.tprintf("recording in %s: %v", dir, e))
		if e := os.make_directory_all(pkg); e != nil do panic(fmt.tprintf("recording in %s: %v", dir, e))
		record_file(fmt.tprintf("%s/pkg.odin", pkg), code)
	}

	// the arguments, as each param's type has them in Args
	literal := strings.builder_make(context.temp_allocator)
	strings.write_string(&literal, "pkg.Args{")
	for p, k in ff.root.params {
		if k >= len(args) do return
		if k > 0 do strings.write_string(&literal, ", ")
		fmt.sbprintf(&literal, "%s = ", codegen_identifier(p.ref_name))
		switch v in args[k] {
		case i64:
			fmt.sbprintf(&literal, "%d", v)
		case bool:
			fmt.sbprintf(&literal, "%v", v)
		case []byte:
			strings.write_byte(&literal, '{')
			for x, i in v do fmt.sbprintf(&literal, i > 0 ? ", %d" : "%d", x)
			strings.write_byte(&literal, '}')
		case string:
			fmt.sbprintf(&literal, "%q", v)
		case i8, i16, i32, u8, u16, u32, u64, f32, f64, ^fld.Instance, []fld.Value:
			return
		}
	}
	strings.write_string(&literal, "}")
	if len(args) != len(ff.root.params) do return

	record_count += 1
	n := record_count
	record_file(fmt.tprintf("%s/cases/%d.bin", dir, n), string(data))
	record_file(fmt.tprintf("%s/cases/%d.args", dir, n), strings.to_string(literal))
	record_file(fmt.tprintf("%s/cases/%d.want", dir, n), decode_result(ff, d))
}

@(private = "file")
record_file :: proc(path, data: string) {
	if e := os.write_entire_file(path, data); e != nil do panic(fmt.tprintf("recording %s: %v", path, e))
}

// The result of a decode as the program that tools/codegen_tests/check.py
// builds writes it: the text dump, or the error, as zelbyn writes it, on a
// line of its own.
@(private = "file")
decode_result :: proc(ff: ^mdata.File_Format, d: ^Decoded) -> string {
	b := strings.builder_make(context.temp_allocator)
	if d.err.kind == .None {
		_ = dmp.write_text(strings.to_writer(&b), ff, &d.tree)
		return strings.to_string(b)
	}
	err := d.err
	fmt.sbprintf(&b, "error: %v at 0x%08X in %s", err.kind, err.offset, err.path)
	if err.value != "" do fmt.sbprintf(&b, ": read %s", err.value)
	if err.expected != "" {
		strings.write_string(&b, err.value != "" ? ", expected " : ": expected ")
		#partial switch err.kind {
		case .Less_Than_Min:
			strings.write_string(&b, "at least ")
		case .Greater_Than_Max:
			strings.write_string(&b, "at most ")
		case .Not_Any_Of, .Not_In_Enum:
			strings.write_string(&b, "one of ")
		}
		strings.write_string(&b, err.expected)
	}
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

// name as generated code names a field or param (codegen.identifier).
@(private = "file")
codegen_identifier :: proc(name: string) -> string {
	return codegen.field_name(name)
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
