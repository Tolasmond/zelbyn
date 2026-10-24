package tests

import dmp "../zelbyn/dump"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

HEADER :: []byte{'G', 'I', 'F', '8', '9', 'a', 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00} // 13 bytes, no GCT

// Returns HEADER followed by suffix; the caller deletes it.
with_header :: proc(suffix: []byte) -> [dynamic]byte {
	data := make([dynamic]byte, 0, len(HEADER) + len(suffix))
	append(&data, ..HEADER)
	append(&data, ..suffix)
	return data
}

@(test)
minimal_valid :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x3B})
	defer delete(data)

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, 14)
	g := root_instance(&ff, &d)
	testing.expect_value(t, len(field_values(g, "blocks")), 0)
	testing.expect_value(t, len(field_values(g, "global_color_table")), 0)
	testing.expect_value(t, field_values(g, "trailer")[0].(u8), 59)
}

// Regression test for B1: a comment extension followed by the trailer as
// the very last byte (the shape that made CG89A.GIF loop forever).
@(test)
comment_then_trailer_at_eof :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21, 0xFE, 0x03, 'a', 'b', 'c', 0x00, 0x3B})
	defer delete(data)

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, 21)

	g := root_instance(&ff, &d)
	if !testing.expect_value(t, len(field_values(g, "blocks")), 1) do return

	block := field_instance(g, "blocks")
	extension := field_instance(block, "extensions")
	comment := field_instance(extension, "comment_extension")
	comment_data := field_instance(comment, "comment_data")
	blob := field_values(comment_data, "data_sub_block_values")[0].([]byte)
	testing.expect_value(t, string(blob), "abc")
}

@(test)
empty_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d: Decoded
	decode_bytes(&ff, {}, &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 0)
	testing.expect_value(t, d.err.path, "GIF89a[0].Signature[0]")
}

@(test)
header_only :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	file, read_err := os.read_entire_file(SAMPLE_855.path, context.allocator)
	if !testing.expectf(t, read_err == nil, "reading %s: %v", SAMPLE_855.path, read_err) do return
	defer delete(file)

	d: Decoded
	decode_bytes(&ff, file[:13], &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0].Global Color Table[0].Red[0]")
}

@(test)
not_a_gif :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	text := "hello world, not a gif at all"
	d: Decoded
	decode_bytes(&ff, transmute([]byte)text, &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Not_Equal)
	testing.expect_value(t, d.err.offset, 0)
	testing.expect_value(t, d.err.path, "GIF89a[0].Signature[0]")
}

@(test)
wrong_version :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x3B})
	defer delete(data)
	data[4] = '7' // GIF87a

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Not_Equal)
	testing.expect_value(t, d.err.offset, 3)
	testing.expect_value(t, d.err.path, "GIF89a[0].Version[0]")
}

// A Graphic Control Extension's block size must be 4.
@(test)
wrong_block_size :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21, 0xF9, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3B})
	defer delete(data)

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Not_Equal)
	testing.expect_value(t, d.err.offset, 15)
	testing.expect_value(t, d.err.path, "GIF89a[0].Blocks[0].Extensions[0].Graphic Control Extension[0].Graphic Control Block Size[0]")
}

// The extension markers' second byte would be past EOF, so every extension
// is absent and the Extensions instance consumes nothing.
@(test)
marker_past_eof_is_absent :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21})
	defer delete(data)

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .No_Progress)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0].Blocks[0].Extensions[0]")
}

@(test)
blob_longer_than_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21, 0xFE, 0x10, 'a', 'b', 'c'})
	defer delete(data)

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 16)
	testing.expect_value(
		t,
		d.err.path,
		"GIF89a[0].Blocks[0].Extensions[0].Comment Extension[0].Comment Data[0].Data Sub-Block Values[0]",
	)
}

@(test)
missing_terminator :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d: Decoded
	decode_bytes(&ff, HEADER, &d)
	defer destroy_decoded(&d)

	// the Blocks terminator peek hits EOF
	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0]")
}

@(test)
missing_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d: Decoded
	decode_file(&ff, "data/does_not_exist.gif", &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .File_Read_Failed)
	testing.expect(t, d.err.os_error != nil, "os_error should be set")
	testing.expect_value(t, d.err.path, "")
}

// Decodes data[:n] for each n in lengths. Prefixes shorter than the full
// decode must fail; longer ones must succeed and consume the same bytes.
@(private = "file")
sweep :: proc(t: ^testing.T, ff: ^mdata.File_Format, s: Sample, lengths: []int) {
	file, read_err := os.read_entire_file(s.path, context.allocator)
	if !testing.expectf(t, read_err == nil, "reading %s: %v", s.path, read_err) do return
	defer delete(file)

	for n in lengths {
		d: Decoded
		decode_bytes(ff, file[:n], &d)
		if n < s.consumed {
			testing.expectf(t, d.err.kind != .None, "%s[:%v]: decoded without error, consumed %v", s.path, n, d.consumed)
		} else {
			testing.expectf(
				t,
				d.err.kind == .None && d.consumed == s.consumed,
				"%s[:%v]: %v at 0x%08X in %s, consumed %v (want %v)",
				s.path, n, d.err.kind, d.err.offset, d.err.path, d.consumed, s.consumed,
			)
		}
		destroy_decoded(&d)
	}
}

@(test)
truncation_sweep_small :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	for s in ([]Sample{SAMPLE_89AILLUS, SAMPLE_TEXTTST}) {
		lengths := make([dynamic]int, 0, s.file_size, context.temp_allocator)
		for n in 0 ..< s.file_size do append(&lengths, n)
		sweep(t, &ff, s, lengths[:])
	}
}

@(test)
truncation_sweep_large :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	for s in ([]Sample{SAMPLE_CG89A, SAMPLE_855}) {
		lengths := make([dynamic]int, context.temp_allocator)
		for n := 0; n <= s.file_size; n += 997 do append(&lengths, n)
		append(&lengths, s.file_size - 1, s.file_size)
		sweep(t, &ff, s, lengths[:])
	}
}

// A count read from the input, far above the bytes left, fails at the end
// of the input as any short read does; it must not reserve room for every
// element first.
@(test)
count_beyond_input :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	SRC :: "meta:\n  id: big\n  endian: le\nseq:\n  - id: n\n    type: u8\n  - id: items\n    type: u1\n    repeat: expr\n    repeat-expr: n\n"

	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile(SRC, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return

	for n in ([?]u64{0xffff_ffff, 1 << 62, u64(max(int))}) {
		input: [10]byte
		for i in 0 ..< 8 do input[i] = byte(n >> (8 * uint(i)))
		input[8], input[9] = 1, 2

		d: Decoded
		decode_bytes(&ff, input[:], &d)
		testing.expectf(t, d.err.kind == .Unexpected_EOF && d.err.offset == 10 && d.err.path == "big[0].items[2]", "n = %v: %v at %v in %s, want Unexpected_EOF at 10 in big[0].items[2]", n, d.err.kind, d.err.offset, d.err.path)
		destroy_decoded(&d)
	}
}

// A negative repeat-expr reads no elements, as in Kaitai's runtimes:
// computed from the input, a negation or an enum constant, and the fields
// after it are read; a negative length is an error where the field starts.
@(test)
negative_count_and_length :: proc(t: ^testing.T) {
	SRC :: "meta:\n  id: neg\nseq:\n  - id: n\n    type: s1\n  - id: items\n    type: u1\n    repeat: expr\n    repeat-expr: n\n  - id: negation\n    type: u1\n    repeat: expr\n    repeat-expr: -1\n  - id: constant\n    type: u1\n    repeat: expr\n    repeat-expr: counts::none\n  - id: m\n    type: s1\n    valid:\n      expr: items.size + negation.size + constant.size == 0\n  - id: data\n    size: m\nenums:\n  counts:\n    -3: none\n"

	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	err := ksy.compile(SRC, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "%v at %v:%v: %s", err.kind, err.line, err.column, err.message) do return

	Case :: struct {
		input: []byte,
		dump:  string, // or the error
	}
	cases := [?]Case {
		{{0xff, 2, 0xaa, 0xbb}, "neg[0].n[0] = -1\nneg[0].m[0] = 2\nneg[0].data[0] = <2 bytes> aa bb\n"},
		{{0x80, 0}, "neg[0].n[0] = -128\nneg[0].m[0] = 0\nneg[0].data[0] = <0 bytes>\n"},
		{{0x01, 7, 0}, "error: Expr_False at 2 in neg[0].m[0]"},
		{{0xff, 0xff}, "error: Invalid_Length at 2 in neg[0].data[0]"},
	}
	for c in cases {
		d: Decoded
		defer destroy_decoded(&d)
		decode_bytes(&ff, c.input, &d)
		got: string
		if d.err.kind != .None {
			got = fmt.tprintf("error: %v at %v in %s", d.err.kind, d.err.offset, d.err.path)
		} else {
			b := strings.builder_make(context.temp_allocator)
			testing.expect(t, dmp.write_text(strings.to_writer(&b), &ff, &d.tree) == .None, "write_text failed")
			got = strings.to_string(b)
		}
		testing.expectf(t, got == c.dump, "%v: got %q, want %q", c.input, got, c.dump)
	}
}
