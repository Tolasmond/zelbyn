package tests

import dmp "../zelbyn/dump"
import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:encoding/json"
import "core:strings"
import "core:testing"
import "core:time"

// Decodes data with SAMPLE_KSY and dumps it into b as JSON (as_json) or
// text. Fails the test and returns false on any error.
dump_sample :: proc(t: ^testing.T, data: []byte, as_json: bool, b: ^strings.Builder, spans := false) -> bool {
	ff: mdata.File_Format
	defer mdata.destroy_file_format(&ff)
	if !load_sample(t, &ff) do return false

	d: Decoded
	decode_bytes(&ff, data, &d, spans)
	defer destroy_decoded(&d)
	if !testing.expectf(t, d.err.kind == .None, "%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path) do return false

	w := strings.to_writer(b)
	err := as_json ? dmp.write_json(w, &ff, &d.tree) : dmp.write_text(w, &ff, &d.tree)
	return testing.expectf(t, err == .None, "dump failed: %v", err)
}

// Each dump of a tree read with spans is the same as without them.
@(test)
dump_sample_exact :: proc(t: ^testing.T) {
	data := sample_input(4)
	defer delete(data)

	want_text := `sample[0].magic[0] = <4 bytes> 53 4d 50 4c
sample[0].name[0] = "sample"
sample[0].num_colors[0] = 3
sample[0].colors[0].r[0] = 255
sample[0].colors[0].g[0] = 0
sample[0].colors[0].b[0] = 0
sample[0].colors[1].r[0] = 0
sample[0].colors[1].g[0] = 255
sample[0].colors[1].b[0] = 0
sample[0].colors[2].r[0] = 0
sample[0].colors[2].g[0] = 0
sample[0].colors[2].b[0] = 255
sample[0].records[0].kind[0] = 1
sample[0].records[0].len[0] = 8
sample[0].records[0].body[0].text[0] = "record 0"
sample[0].records[1].kind[0] = 2
sample[0].records[1].len[0] = 3
sample[0].records[1].body[0].hi[0] = 0
sample[0].records[1].body[0].lo[0] = 1
sample[0].records[1].body[0].rest[0] = <2 bytes> ab cd
sample[0].records[2].kind[0] = 7
sample[0].records[2].len[0] = 3
sample[0].records[2].body[0] = <3 bytes> 02 03 04
sample[0].records[3].kind[0] = 1
sample[0].records[3].len[0] = 8
sample[0].records[3].body[0].text[0] = "record 3"
sample[0].last[0] = 51
`
	want_json := `{"sample":[{"magic":["534d504c"],"name":["sample"],"num_colors":[3],"colors":[{"r":[255],"g":[0],"b":[0]},{"r":[0],"g":[255],"b":[0]},{"r":[0],"g":[0],"b":[255]}],"records":[{"kind":[1],"len":[8],"body":[{"text":["record 0"]}]},{"kind":[2],"len":[3],"body":[{"hi":[0],"lo":[1],"rest":["abcd"]}]},{"kind":[7],"len":[3],"body":["020304"]},{"kind":[1],"len":[8],"body":[{"text":["record 3"]}]}],"last":[51]}]}` + "\n"

	for as_json in ([?]bool{false, true}) {
		for spans in ([?]bool{false, true}) {
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			if !dump_sample(t, data[:], as_json, &b, spans) do continue
			want := as_json ? want_json : want_text
			testing.expectf(t, strings.to_string(b) == want, "json %v, spans %v:\ngot:\n%s\nwant:\n%s", as_json, spans, strings.to_string(b), want)
		}
	}
}

@(test)
field_write_value :: proc(t: ^testing.T) {
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
		err := fld.write_value(strings.to_writer(&b), c.v)
		testing.expectf(t, err == .None, "write_value(%v): %v", c.v, err)
		testing.expect_value(t, strings.to_string(b), c.want)
	}
}

// The JSON dump of a large tree parses.
@(test)
dump_json_large_parses :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	data := sample_input(20000)
	defer delete(data)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	if !dump_sample(t, data[:], true, &b) do return
	check_json_parses(t, strings.to_string(b))
}

@(private = "file")
check_json_parses :: proc(t: ^testing.T, text: string) {
	v, err := json.parse_string(text, .JSON)
	defer json.destroy_value(v)
	testing.expectf(t, err == .None, "JSON does not parse: %v", err)
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
