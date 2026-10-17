package tests

import mdat "../gnrcrdr/metadata"
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

	g := set_of(d.tree.root[0])
	lsd := set_of(g[5003][0])
	testing.expectf(t, lsd[5004][0].(u16) == s.width, "%s: width %v, want %v", s.path, lsd[5004][0], s.width)
	testing.expectf(t, lsd[5005][0].(u16) == s.height, "%s: height %v, want %v", s.path, lsd[5005][0], s.height)
	testing.expectf(t, len(g[5013]) == s.gct_len, "%s: %v GCT entries, want %v", s.path, len(g[5013]), s.gct_len)
	testing.expectf(t, len(g[5017]) == s.blocks, "%s: %v blocks, want %v", s.path, len(g[5017]), s.blocks)
	if len(g[5013]) > 0 {
		red := set_of(g[5013][0])[5014][0].(u8)
		testing.expectf(t, red == s.first_red, "%s: first GCT red %v, want %v", s.path, red, s.first_red)
	}
	testing.expectf(t, g[5068][0].(u8) == s.trailer, "%s: trailer %v, want %v", s.path, g[5068][0], s.trailer)
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

	g := set_of(d.tree.root[0])
	testing.expect_value(t, g[5001][0].(string), "GIF")
	testing.expect_value(t, g[5002][0].(string), "89a")

	first := set_of(g[5013][0])
	testing.expect_value(t, first[5014][0].(u8), 252)
	testing.expect_value(t, first[5015][0].(u8), 243)
	testing.expect_value(t, first[5016][0].(u8), 233)
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
