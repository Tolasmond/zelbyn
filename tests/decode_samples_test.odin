package tests

import mdat "../zelbyn/metadata"
import "core:os"
import "core:testing"
import "core:time"

Sample :: struct {
	path:      string,
	consumed:  int,
	file_size: int,
	width:     u16,
	height:    u16,
	gct_len:   int,
	blocks:    int,
	first_red: u8,
	trailer:   u8,
}

SAMPLE_855      :: Sample{"data/855.gif",      922706, 922706, 500, 228, 128, 30, 252, 59}
SAMPLE_89AILLUS :: Sample{"data/89AILLUS.GIF", 2657,   2688,   640, 480, 16,  1,  255, 59}
SAMPLE_BOB_89A  :: Sample{"data/BOB_89A.GIF",  37062,  37120,  320, 200, 128, 2,  0,   59}
SAMPLE_CG89A    :: Sample{"data/CG89A.GIF",    26624,  26624,  320, 200, 256, 3,  16,  59}
SAMPLE_STIGR9   :: Sample{"data/STIGR9.GIF",   159007, 159104, 640, 480, 256, 49, 0,   59}
SAMPLE_TEXTTST  :: Sample{"data/TEXTTST.GIF",  1157,   1536,   320, 200, 256, 1,  16,  59}

// Decodes a sample file and checks it against the golden values.
check_sample :: proc(t: ^testing.T, s: Sample) {
	testing.set_fail_timeout(t, 10 * time.Second)

	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	info, stat_err := os.stat(s.path, context.temp_allocator)
	if testing.expectf(t, stat_err == nil, "%s: stat failed: %v", s.path, stat_err) {
		testing.expectf(t, int(info.size) == s.file_size, "%s: file size %v, want %v", s.path, info.size, s.file_size)
	}

	d: Decoded
	decode_file(&ff, s.path, &d)
	defer destroy_decoded(&d)

	if !testing.expectf(t, d.err.kind == .None, "%s: %v at 0x%08X in %s", s.path, d.err.kind, d.err.offset, d.err.path) do return
	testing.expectf(t, d.consumed == s.consumed, "%s: consumed %v, want %v", s.path, d.consumed, s.consumed)

	g := root_instance(&ff, &d)
	lsd := field_instance(g, "logical_screen_descriptor")
	width, height := field_values(lsd, "logical_screen_width")[0], field_values(lsd, "logical_screen_height")[0]
	testing.expectf(t, width.(u16) == s.width, "%s: width %v, want %v", s.path, width, s.width)
	testing.expectf(t, height.(u16) == s.height, "%s: height %v, want %v", s.path, height, s.height)
	gct, blocks := field_values(g, "global_color_table"), field_values(g, "blocks")
	testing.expectf(t, len(gct) == s.gct_len, "%s: %v GCT entries, want %v", s.path, len(gct), s.gct_len)
	testing.expectf(t, len(blocks) == s.blocks, "%s: %v blocks, want %v", s.path, len(blocks), s.blocks)
	if len(gct) > 0 {
		red := field_values(field_instance(g, "global_color_table"), "red")[0].(u8)
		testing.expectf(t, red == s.first_red, "%s: first GCT red %v, want %v", s.path, red, s.first_red)
	}
	trailer := field_values(g, "trailer")[0]
	testing.expectf(t, trailer.(u8) == s.trailer, "%s: trailer %v, want %v", s.path, trailer, s.trailer)
}

@(test)
decode_855 :: proc(t: ^testing.T) {
	check_sample(t, SAMPLE_855)

	// extra checks on header strings and the first colour
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	d: Decoded
	decode_file(&ff, SAMPLE_855.path, &d)
	defer destroy_decoded(&d)
	if d.err.kind != .None do return

	g := root_instance(&ff, &d)
	testing.expect_value(t, field_values(g, "signature")[0].(string), "GIF")
	testing.expect_value(t, field_values(g, "version")[0].(string), "89a")

	first := field_instance(g, "global_color_table")
	testing.expect_value(t, field_values(first, "red")[0].(u8), 252)
	testing.expect_value(t, field_values(first, "green")[0].(u8), 243)
	testing.expect_value(t, field_values(first, "blue")[0].(u8), 233)
}

@(test)
decode_89AILLUS :: proc(t: ^testing.T) {
	check_sample(t, SAMPLE_89AILLUS)
}

@(test)
decode_BOB_89A :: proc(t: ^testing.T) {
	check_sample(t, SAMPLE_BOB_89A)
}

// Regression test for B1: this file ends exactly at its trailer.
@(test)
decode_CG89A :: proc(t: ^testing.T) {
	check_sample(t, SAMPLE_CG89A)
}

@(test)
decode_STIGR9 :: proc(t: ^testing.T) {
	check_sample(t, SAMPLE_STIGR9)
}

@(test)
decode_TEXTTST :: proc(t: ^testing.T) {
	check_sample(t, SAMPLE_TEXTTST)
}
