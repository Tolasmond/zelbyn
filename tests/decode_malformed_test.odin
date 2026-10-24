package tests

import dmp "../zelbyn/dump"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
empty_input :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	d: Decoded
	decode_bytes(&ff, {}, &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 0)
	testing.expect_value(t, d.err.path, "sample[0].magic[0]")
}

@(test)
wrong_contents :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	text := "hello world, not a sample at all"
	d: Decoded
	decode_bytes(&ff, transmute([]byte)text, &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Not_Equal)
	testing.expect_value(t, d.err.offset, 0)
	testing.expect_value(t, d.err.path, "sample[0].magic[0]")
}

// A record's size runs past the end of the input: the error is where the
// field starts.
@(test)
size_past_end :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	data := sample_input(1)
	defer delete(data)
	data[len(data) - 9] = 20 // the first record's len, 8, now beyond its text

	d: Decoded
	decode_bytes(&ff, data[:], &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, len(data) - 8)
	testing.expect_value(t, d.err.path, "sample[0].records[0].body[0]")
}

@(test)
missing_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return

	d: Decoded
	decode_file(&ff, "tests/does_not_exist.bin", &d)
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .File_Read_Failed)
	testing.expect(t, d.err.os_error != nil, "os_error should be set")
	testing.expect_value(t, d.err.path, "")
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
