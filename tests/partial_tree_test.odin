package tests

import fld "../zelbyn/field"
import ksy "../zelbyn/ksy"
import mdata "../zelbyn/metadata"
import "core:fmt"
import "core:testing"
import "core:time"

// What a tree holds after a failed decode (doc/arch.md §7.10): each case
// decodes an input that fails, with spans, and compares the whole tree,
// sets included, with the lines it should give.
@(test)
partial_trees :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	Case :: struct {
		name:   string,
		ksy:    string,
		input:  []byte,
		args:   []fld.Value,
		err:    string,
		want:   string,
	}
	cases := [?]Case {
		{
			// the array has the elements read; the instance being read has
			// the values read in it, from its start to the failed read
			name = "repeat of sets",
			ksy = "meta:\n  id: p\nseq:\n  - id: n\n    type: u1\n  - id: items\n    type: item\n    repeat: expr\n    repeat-expr: n\n  - id: tail\n    type: u1\ntypes:\n  item:\n    seq:\n      - id: a\n        type: u1\n      - id: b\n        type: u2le\n",
			input = {3, 1, 2, 0, 3, 4, 0, 5},
			err = "Unexpected_EOF at 0x00000008 in p[0].items[2].b[0]",
			want = `p[0] {} @0+8
p[0].n[0] = 3 @0+1
p[0].items[0] {} @1+3
p[0].items[0].a[0] = 1 @1+1
p[0].items[0].b[0] = 2 @2+2
p[0].items[1] {} @4+3
p[0].items[1].a[0] = 3 @4+1
p[0].items[1].b[0] = 4 @5+2
p[0].items[2] {} @7+1
p[0].items[2].a[0] = 5 @7+1
`,
		},
		{
			// an instance of a substream spans the substream, as when it is
			// read
			name = "substream",
			ksy = "meta:\n  id: p\nseq:\n  - id: len\n    type: u1\n  - id: body\n    type: body\n    size: len\ntypes:\n  body:\n    seq:\n      - id: a\n        type: u1\n      - id: b\n        type: u4le\n",
			input = {3, 7, 8, 9},
			err = "Unexpected_EOF at 0x00000002 in p[0].body[0].b[0]",
			want = `p[0] {} @0+4
p[0].len[0] = 3 @0+1
p[0].body[0] {} @1+3
p[0].body[0].a[0] = 7 @1+1
`,
		},
		{
			// a value that fails its check is in the tree, as read
			name = "failed check",
			ksy = "meta:\n  id: p\nseq:\n  - id: hdr\n    type: hdr\n  - id: rest\n    type: u1\ntypes:\n  hdr:\n    seq:\n      - id: version\n        type: u1\n        valid:\n          max: 2\n      - id: flags\n        type: u1\n",
			input = {9, 1, 2},
			err = "Greater_Than_Max at 0x00000000 in p[0].hdr[0].version[0]: read 9, expected 2",
			want = `p[0] {} @0+1
p[0].hdr[0] {} @0+1
p[0].hdr[0].version[0] = 9 @0+1
`,
		},
		{
			// its -bits fields are not: they have one value fewer
			name = "failed check with -bits",
			ksy = "meta:\n  id: p\nseq:\n  - id: flags\n    type: u1\n    repeat: expr\n    repeat-expr: 2\n    valid:\n      max: 0x7f\n    -bits:\n      - {id: lo, low: 0, high: 3}\n      - {id: hi, low: 4, high: 7}\n",
			input = {0x21, 0xf5},
			err = "Greater_Than_Max at 0x00000001 in p[0].flags[1]: read 245, expected 127",
			want = `p[0] {} @0+2
p[0].flags[0] = 33 @0+1
p[0].flags[1] = 245 @1+1
p[0].lo[0] = 1 @0+1
p[0].hi[0] = 2 @0+1
`,
		},
		{
			// the case a switch-on chose is recorded from the start
			name = "switch-on",
			ksy = "meta:\n  id: p\nseq:\n  - id: kind\n    type: u1\n  - id: body\n    type:\n      switch-on: kind\n      cases:\n        1: one\n        2: two\ntypes:\n  one:\n    seq:\n      - id: x\n        type: u1\n  two:\n    seq:\n      - id: y\n        type: u1\n      - id: z\n        type: u2le\n",
			input = {2, 5, 6},
			err = "Unexpected_EOF at 0x00000002 in p[0].body[0].z[0]",
			want = `p[0] {} @0+2
p[0].kind[0] = 2 @0+1
p[0].body[0] {} @1+1
p[0].body[0].y[0] = 5 @1+1
`,
		},
		{
			// values read from decompressed bytes are kept, at their
			// field's offset plus their position in the bytes
			name = "zlib",
			// "AB", compressed
			ksy = "meta:\n  id: p\nseq:\n  - id: len\n    type: u1\n  - id: body\n    type: body\n    size: len\n    process: zlib\ntypes:\n  body:\n    seq:\n      - id: a\n        type: u1\n      - id: b\n        type: u2le\n",
			input = {10, 0x78, 0x9c, 0x73, 0x74, 0x02, 0x00, 0x00, 0xc6, 0x00, 0x84},
			err = "Unexpected_EOF at 0x00000002 in p[0].body[0].b[0]",
			want = `p[0] {} @0+11
p[0].len[0] = 10 @0+1
p[0].body[0] {} @1+10
p[0].body[0].a[0] = 65 @1+1
`,
		},
		{
			// a parse instance not read yet has no values; one whose read
			// failed has those it read
			name = "parse instances",
			ksy = "meta:\n  id: p\nseq:\n  - id: a\n    type: u1\ninstances:\n  first:\n    pos: 0\n    type: u1\n  far:\n    pos: 1\n    type: pair\ntypes:\n  pair:\n    seq:\n      - id: x\n        type: u1\n      - id: y\n        type: u1\n",
			input = {4, 5},
			err = "Unexpected_EOF at 0x00000002 in p[0].far[0].y[0]",
			want = `p[0] {} @0+1
p[0].a[0] = 4 @0+1
p[0].first[0] = 4 @0+1
p[0].far[0] {} @1+1
p[0].far[0].x[0] = 5 @1+1
`,
		},
		{
			// the root's own instance is there from its start
			name = "empty input",
			ksy = "meta:\n  id: p\nseq:\n  - id: a\n    type: u1\n",
			input = {},
			err = "Unexpected_EOF at 0x00000000 in p[0].a[0]",
			want = "p[0] {} @0+0\n",
		},
		{
			// the argument of a param of a user type is read before the
			// root, which is empty when it fails
			name = "error before the root",
			ksy = "meta:\n  id: p\nparams:\n  - id: h\n    type: hdr\nseq:\n  - id: a\n    type: u1\ntypes:\n  hdr:\n    seq:\n      - id: x\n        type: u2le\n",
			input = {1},
			args = {[]byte{7}},
			err = "Unexpected_EOF at 0x00000000 in h[0].x[0]",
			want = "",
		},
	}

	for c in cases {
		for spans in ([?]bool{true, false}) {
			ff: mdata.File_Format
			defer mdata.destroy_file_format(&ff)
			err := ksy.compile(c.ksy, &ff)
			defer ksy.destroy_error(&err)
			if !testing.expectf(t, err.kind == .None, "%s: compile: %v %s", c.name, err.kind, err.message) do continue

			d: Decoded
			defer destroy_decoded(&d)
			decode_bytes(&ff, c.input, &d, spans, c.args)
			got_err := fmt.tprintf("%v at 0x%08X in %s", d.err.kind, d.err.offset, d.err.path)
			if d.err.value != "" do got_err = fmt.tprintf("%s: read %s, expected %s", got_err, d.err.value, d.err.expected)
			testing.expectf(t, got_err == c.err, "%s, spans %v: error\n%s\nwant\n%s", c.name, spans, got_err, c.err)

			got := tree_lines(&ff, &d.tree)
			want := c.want
			if !spans do want = without_spans(want)
			testing.expectf(t, got == want, "%s, spans %v: tree\n%s\nwant\n%s", c.name, spans, got, want)
		}
	}
}
