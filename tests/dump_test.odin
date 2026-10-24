package tests

import dmp "../zelbyn/dump"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:time"

// Decodes path and dumps it into b as JSON (as_json) or text. Fails the
// test and returns false on any error.
dump_sample :: proc(t: ^testing.T, path: string, as_json: bool, b: ^strings.Builder, source := Schema_Source.Ported, spans := false) -> bool {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_gif_from(t, source, &ff) do return false

	d: Decoded
	decode_file(&ff, path, &d, spans)
	defer destroy_decoded(&d)
	if !testing.expectf(t, d.err.kind == .None, "%s: %v at 0x%08X in %s", path, d.err.kind, d.err.offset, d.err.path) do return false

	w := strings.to_writer(b)
	err := as_json ? dmp.write_json(w, &ff, &d.tree) : dmp.write_text(w, &ff, &d.tree)
	return testing.expectf(t, err == .None, "%s: dump failed: %v", path, err)
}

@(test)
dump_text_855 :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	if !dump_sample(t, SAMPLE_855.path, false, &b) do return

	want := [?]string{
		`GIF89a[0].Signature[0] = "GIF"`,
		`GIF89a[0].Version[0] = "89a"`,
		`GIF89a[0].Logical Screen Descriptor[0].Logical Screen Width[0] = 500`,
		`GIF89a[0].Logical Screen Descriptor[0].Logical Screen Height[0] = 228`,
		`GIF89a[0].Logical Screen Descriptor[0].Logical Screen Descriptor Packed Fields[0] = 246`,
		`GIF89a[0].Logical Screen Descriptor[0].Size of Global Color Table[0] = 6`,
		`GIF89a[0].Logical Screen Descriptor[0].Sort Flag[0] = 0`,
		`GIF89a[0].Logical Screen Descriptor[0].Color Resolution[0] = 7`,
		`GIF89a[0].Logical Screen Descriptor[0].Global Color Table Flag[0] = 1`,
		`GIF89a[0].Logical Screen Descriptor[0].Background Color Index[0] = 127`,
		`GIF89a[0].Logical Screen Descriptor[0].Pixel Aspect Ratio[0] = 0`,
		`GIF89a[0].Global Color Table[0].Red[0] = 252`,
		`GIF89a[0].Global Color Table[0].Green[0] = 243`,
		`GIF89a[0].Global Color Table[0].Blue[0] = 233`,
		`GIF89a[0].Global Color Table[1].Red[0] = 93`,
	}

	text := strings.to_string(b)
	testing.expect(t, strings.has_suffix(text, "\n"), "text dump does not end in a newline")

	lines := strings.split_lines(strings.trim_suffix(text, "\n"))
	defer delete(lines)

	// one line per per-value "Read" line in the debug log of the run before
	// bit fields were decoded, and one per bit field value
	testing.expect_value(t, len(lines), 8114 + 214)
	for line, i in want {
		if i >= len(lines) do break
		testing.expectf(t, lines[i] == line, "line %v = %q, want %q", i + 1, lines[i], line)
	}
}

@(test)
dump_write_value :: proc(t: ^testing.T) {
	seventeen: [17]byte
	for &x, i in seventeen do x = byte(i)

	Case :: struct {
		v:    fld.Value,
		want: string,
	}
	cases := [?]Case{
		{i8(-2), "-2"},
		{max(u64), "18446744073709551615"},
		{f32(1.5), "1.5"},
		{"a\"b", `"a\"b"`},
		{[]byte{}, "<0 bytes>"},
		{[]byte{0x00, 0xAB, 0xFF}, "<3 bytes> 00 ab ff"},
		{seventeen[:], "<17 bytes> 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f ..."},
	}

	for c in cases {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		err := dmp.write_value(strings.to_writer(&b), c.v)
		testing.expectf(t, err == .None, "write_value(%v): %v", c.v, err)
		testing.expect_value(t, strings.to_string(b), c.want)
	}
}

@(test)
dump_json_855 :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	if !dump_sample(t, SAMPLE_855.path, true, &b) do return

	text := strings.to_string(b)
	prefix := `{"GIF89a":[{"Signature":["GIF"],"Version":["89a"],"Logical Screen Descriptor":[{"Logical Screen Width":[500],"Logical Screen Height":[228],`
	testing.expectf(t, strings.has_prefix(text, prefix), "JSON starts %q, want %q", text[:min(len(text), len(prefix))], prefix)
	testing.expect(t, strings.has_suffix(text, "}\n"), "JSON does not end in }\\n")

	check_json_parses(t, SAMPLE_855.path, text)
}

@(test)
dump_json_samples_parse :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	for s in ([?]Sample{SAMPLE_89AILLUS, SAMPLE_BOB_89A, SAMPLE_CG89A, SAMPLE_STIGR9, SAMPLE_TEXTTST}) {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		if !dump_sample(t, s.path, true, &b) do continue

		check_json_parses(t, s.path, strings.to_string(b))
	}
}

@(private = "file")
check_json_parses :: proc(t: ^testing.T, path: string, text: string) {
	v, err := json.parse_string(text, .JSON)
	defer json.destroy_value(v)
	testing.expectf(t, err == .None, "%s: JSON does not parse: %v", path, err)
}

// A string is written as valid JSON whatever its bytes: escapes as
// json.marshal writes them, and \u00NN for each byte that is not part of
// valid UTF-8 (a lone byte, a truncated sequence, an encoded surrogate, an
// overlong encoding).
@(test)
dump_json_string_bytes :: proc(t: ^testing.T) {
	input := []byte {
		'a', '"', '\\', '\n', 0x01, 0x7f,
		0xc3, 0xa9, // é
		0xc2, 0xad, // U+00AD, the soft hyphen
		0xf0, 0x9f, 0x98, 0x80, // U+1F600
		0xff,
		0xc3, 'b',
		0xed, 0xa0, 0x80,
		0xc0, 0xaf,
	}
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	src := "meta:\n  id: t\nseq:\n  - id: s\n    type: str\n    size: 22\n    encoding: UTF-8\n"
	err := ksy.compile(src, &ff)
	defer ksy.destroy_error(&err)
	if !testing.expectf(t, err.kind == .None, "compile: %v: %s", err.kind, err.message) do return

	d: Decoded
	defer destroy_decoded(&d)
	decode_bytes(&ff, input, &d)
	if !testing.expectf(t, d.err.kind == .None, "decode: %v at %v in %s", d.err.kind, d.err.offset, d.err.path) do return

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect(t, dmp.write_json(strings.to_writer(&b), &ff, &d.tree) == .None, "write_json failed")
	text := strings.to_string(b)
	testing.expect_value(t, text, `{"t":[{"s":["a\"\\\n\u0001\u007fé\u00ad\ud83d\ude00\u00ff\u00c3b\u00ed\u00a0\u0080\u00c0\u00af"]}]}` + "\n")

	// a JSON reader sees each such byte as the character of the same value
	v, perr := json.parse_string(text, .JSON)
	defer json.destroy_value(v)
	if !testing.expectf(t, perr == .None, "JSON does not parse: %v", perr) do return
	got := v.(json.Object)["t"].(json.Array)[0].(json.Object)["s"].(json.Array)[0].(json.String)
	testing.expect_value(t, got, "a\"\\\n\x01\x7f\u00e9\u00ad\U0001f600\u00ff\u00c3b\u00ed\u00a0\u0080\u00c0\u00af")
}
