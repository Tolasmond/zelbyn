package tests

import fld "../gnrcrdr/field"
import mdat "../gnrcrdr/metadata"
import "core:os"
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
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x3B})
	defer delete(data)

	d := decode_bytes(&ff, data[:])
	defer destroy_decoded(&d)

	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, 14)
	g := set_of(d.root[0])
	testing.expect_value(t, len(g[5017]), 0)
	testing.expect_value(t, len(g[5013]), 0)
	testing.expect_value(t, g[5068][0].(u8), 59)
}

// Regression test for B1: a comment extension followed by the trailer as
// the very last byte (the shape that made CG89A.GIF loop forever).
@(test)
comment_then_trailer_at_eof :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21, 0xFE, 0x03, 'a', 'b', 'c', 0x00, 0x3B})
	defer delete(data)

	d := decode_bytes(&ff, data[:])
	defer destroy_decoded(&d)

	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return
	testing.expect_value(t, d.consumed, 21)

	g := set_of(d.root[0])
	if !testing.expect_value(t, len(g[5017]), 1) do return

	block := set_of(g[5017][0])
	extension := set_of(block[5018][0])
	comment := set_of(extension[5030][0])
	comment_data := set_of(comment[5032][0])
	blob := comment_data[5052][0].([]byte)
	testing.expect_value(t, string(blob), "abc")
}

@(test)
empty_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d := decode_bytes(&ff, {})
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 0)
	testing.expect_value(t, d.err.path, "GIF89a[0].Signature[0]")
}

@(test)
header_only :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	file, read_err := os.read_entire_file(SAMPLE_855.path, context.allocator)
	if !testing.expectf(t, read_err == nil, "reading %s: %v", SAMPLE_855.path, read_err) do return
	defer delete(file)

	d := decode_bytes(&ff, file[:13])
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0].Global Color Table[0].Red[0]")
}

@(test)
not_a_gif :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	text := "hello world, not a gif at all"
	d := decode_bytes(&ff, transmute([]byte)text)
	defer destroy_decoded(&d)

	testing.expect_value(t, len(text), 29)
	testing.expect_value(t, d.err.kind, .No_Progress)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0].Blocks[0]")
}

// The extension markers' second byte would be past EOF, so every extension
// is absent and the Extensions instance consumes nothing.
@(test)
marker_past_eof_is_absent :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21})
	defer delete(data)

	d := decode_bytes(&ff, data[:])
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .No_Progress)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0].Blocks[0].Extensions[0]")
}

@(test)
blob_longer_than_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	data := with_header({0x21, 0xFE, 0x10, 'a', 'b', 'c'})
	defer delete(data)

	d := decode_bytes(&ff, data[:])
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
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d := decode_bytes(&ff, HEADER)
	defer destroy_decoded(&d)

	// the Blocks terminator peek hits EOF
	testing.expect_value(t, d.err.kind, .Unexpected_EOF)
	testing.expect_value(t, d.err.offset, 13)
	testing.expect_value(t, d.err.path, "GIF89a[0]")
}

@(test)
missing_file :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d := decode_file(&ff, "data/does_not_exist.gif")
	defer destroy_decoded(&d)

	testing.expect_value(t, d.err.kind, .File_Read_Failed)
	testing.expect(t, d.err.os_error != nil, "os_error should be set")
	testing.expect_value(t, d.err.path, "")
}

// Decodes data[:n] for each n in lengths. Prefixes shorter than the full
// decode must fail; longer ones must succeed and consume the same bytes.
@(private = "file")
sweep :: proc(t: ^testing.T, ff: ^mdat.File_Format, s: Sample, lengths: []int) {
	file, read_err := os.read_entire_file(s.path, context.allocator)
	if !testing.expectf(t, read_err == nil, "reading %s: %v", s.path, read_err) do return
	defer delete(file)

	for n in lengths {
		d := decode_bytes(ff, file[:n])
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
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
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
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	for s in ([]Sample{SAMPLE_CG89A, SAMPLE_855}) {
		lengths := make([dynamic]int, context.temp_allocator)
		for n := 0; n <= s.file_size; n += 997 do append(&lengths, n)
		append(&lengths, s.file_size - 1, s.file_size)
		sweep(t, &ff, s, lengths[:])
	}
}

@(test)
checked_count_limits :: proc(t: ^testing.T) {
	testing.expect_value(t, fld.check_count(-1, nil), .Invalid_Length)
	testing.expect_value(t, fld.check_count(5, 4), .Repeat_Limit_Exceeded)
	testing.expect_value(t, fld.check_count(4, 4), .None)
	testing.expect_value(t, fld.check_count(10, nil), .None)
}
