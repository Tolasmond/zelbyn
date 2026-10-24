package tests

import yml "../zelbyn/yaml"
import "core:fmt"
import "core:strings"
import "core:testing"

// The tree as one line per node, in the form of tools/yaml_corpus: MAP and
// SEQ with their position, then their contents and END; SCALAR with its
// position, style and text (%q).
@(private = "file")
tree_text :: proc(n: ^yml.Node, b: ^strings.Builder) {
	switch n.kind {
	case .Scalar:
		fmt.sbprintfln(b, "SCALAR %v:%v %v %q", n.line, n.column, n.style, n.text)
	case .Map:
		fmt.sbprintfln(b, "MAP %v:%v", n.line, n.column)
		for e in n.entries {
			tree_text(e.key, b)
			tree_text(e.value, b)
		}
		strings.write_string(b, "END\n")
	case .Seq:
		fmt.sbprintfln(b, "SEQ %v:%v", n.line, n.column)
		for item in n.items do tree_text(item, b)
		strings.write_string(b, "END\n")
	}
}

@(private = "file")
Yaml_Case :: struct {
	name, src, want: string,
}

// Each want was checked against libyaml (PyYAML's CParser).
@(private = "file")
YAML_CASES := [?]Yaml_Case {
	{"block mapping and sequence", "a: 1\nb:\n  - x\n  -\n  - k: v\n    k2:\nc: ~\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SCALAR 1:4 Plain "1"
SCALAR 2:1 Plain "b"
SEQ 3:3
SCALAR 3:5 Plain "x"
SCALAR 4:4 Plain ""
MAP 5:5
SCALAR 5:5 Plain "k"
SCALAR 5:8 Plain "v"
SCALAR 6:5 Plain "k2"
SCALAR 6:8 Plain ""
END
END
SCALAR 7:1 Plain "c"
SCALAR 7:4 Plain "~"
END
`},
	{"sequence in the column of its key", "k:\n- a\n- - x\n  - y\nz: 0x21\n", `MAP 1:1
SCALAR 1:1 Plain "k"
SEQ 2:1
SCALAR 2:3 Plain "a"
SEQ 3:3
SCALAR 3:5 Plain "x"
SCALAR 4:5 Plain "y"
END
END
SCALAR 5:1 Plain "z"
SCALAR 5:4 Plain "0x21"
END
`},
	{"plain scalars", "a: plain\n  continued\n   more\n\n  para\nb: url://x#y z:w # comment\nc: -orig-id\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SCALAR 1:4 Plain "plain continued more\npara"
SCALAR 6:1 Plain "b"
SCALAR 6:4 Plain "url://x#y z:w"
SCALAR 7:1 Plain "c"
SCALAR 7:4 Plain "-orig-id"
END
`},
	{"quoted scalars", "\"a\": \"multi\n  line\n\n  para\"\n'b': 'it''s\n  folded'\nc: \"\\t\\x41\\u00e9\\U0001F600\\\\\\\"\\/\"\nd: \"join \\\n   next\"\n", `MAP 1:1
SCALAR 1:1 Double_Quoted "a"
SCALAR 1:6 Double_Quoted "multi line\npara"
SCALAR 5:1 Single_Quoted "b"
SCALAR 5:6 Single_Quoted "it's folded"
SCALAR 7:1 Plain "c"
SCALAR 7:4 Double_Quoted "\tAé\U0001f600\\\"/"
SCALAR 8:1 Plain "d"
SCALAR 8:4 Double_Quoted "join next"
END
`},
	{"block scalars", "a: >\n  one\n  two\n\n  three\n    indented\n  back\n\n\nb: |+\n  keep\n\n\nc: |-\n  strip\n\nd: |2\n    two extra\n   one\ne: |\n  x\n  # not a comment\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SCALAR 1:4 Folded "one two\nthree\n  indented\nback\n"
SCALAR 10:1 Plain "b"
SCALAR 10:4 Literal "keep\n\n\n"
SCALAR 14:1 Plain "c"
SCALAR 14:4 Literal "strip"
SCALAR 17:1 Plain "d"
SCALAR 17:4 Literal "  two extra\n one\n"
SCALAR 20:1 Plain "e"
SCALAR 20:4 Literal "x\n# not a comment\n"
END
`},
	{"flow collections", "a: [1, [2, 3], {k: v, k2: [x]}, \"q\"]\nb: {a: 1,\n  b: 2,  # c\n  c: }\nc: []\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SEQ 1:4
SCALAR 1:5 Plain "1"
SEQ 1:8
SCALAR 1:9 Plain "2"
SCALAR 1:12 Plain "3"
END
MAP 1:16
SCALAR 1:17 Plain "k"
SCALAR 1:20 Plain "v"
SCALAR 1:23 Plain "k2"
SEQ 1:27
SCALAR 1:28 Plain "x"
END
END
SCALAR 1:33 Double_Quoted "q"
END
SCALAR 2:1 Plain "b"
MAP 2:4
SCALAR 2:5 Plain "a"
SCALAR 2:8 Plain "1"
SCALAR 3:3 Plain "b"
SCALAR 3:6 Plain "2"
SCALAR 4:3 Plain "c"
SCALAR 4:6 Plain ""
END
SCALAR 5:1 Plain "c"
SEQ 5:4
END
END
`},
	{"BOM, CRLF and characters beyond ASCII", "\xef\xbb\xbfé: [ü, \"ö\"]\r\nb: |\r\n  l1\r\n  l2\r\n", `MAP 1:1
SCALAR 1:1 Plain "é"
SEQ 1:4
SCALAR 1:5 Plain "ü"
SCALAR 1:8 Double_Quoted "ö"
END
SCALAR 2:1 Plain "b"
SCALAR 2:4 Literal "l1\nl2\n"
END
`},
	{"document markers", "---\na: 1\n...\n", `MAP 2:1
SCALAR 2:1 Plain "a"
SCALAR 2:4 Plain "1"
END
`},
	{"comments only", "# nothing\n\n", ""},
	{"comments right after flow punctuation", "a: [x,# c\n y, url#frag, z# no]\nb: {# c\n k: 1,# c\n \"q\":# c\n 2}# c\nc: |# c\n  t\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SEQ 1:4
SCALAR 1:5 Plain "x"
SCALAR 2:2 Plain "y"
SCALAR 2:5 Plain "url#frag"
SCALAR 2:15 Plain "z# no"
END
SCALAR 3:1 Plain "b"
MAP 3:4
SCALAR 4:2 Plain "k"
SCALAR 4:5 Plain "1"
SCALAR 5:2 Double_Quoted "q"
SCALAR 6:2 Plain "2"
END
SCALAR 7:1 Plain "c"
SCALAR 7:4 Literal "t\n"
END
`},
	{"a comment right after [", "- [# c\n  x]# c\n", `SEQ 1:1
SEQ 1:3
SCALAR 2:3 Plain "x"
END
END
`},
	{"escapes at the edges", "a: \"\\U0010FFFF\\uD7FF\\uE000\\0\\x01\\x7f\"\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SCALAR 1:4 Double_Quoted "\U0010ffff\ud7ff\ue000\x00\x01\u007f"
END
`},
	{"characters allowed raw", "\xef\xbb\xbfa: \"\t\xc2\x85\xc2\xa0\xef\xbf\xbd\xf4\x8f\xbf\xbf\"\r\n\xc3\xa9: \xef\xbb\xbf\n", `MAP 1:1
SCALAR 1:1 Plain "a"
SCALAR 1:4 Double_Quoted "\t\u0085\u00a0\ufffd\U0010ffff"
SCALAR 2:1 Plain "é"
SCALAR 2:4 Plain "\ufeff"
END
`},
}

@(test)
yaml_trees :: proc(t: ^testing.T) {
	for c in YAML_CASES {
		doc: yml.Document
		defer yml.destroy_document(&doc)
		err := yml.parse(c.src, &doc)
		defer yml.destroy_error(&err)
		if !testing.expectf(t, err.kind == .None, "%s: %v at %v:%v: %s", c.name, err.kind, err.line, err.column, err.message) do continue

		b := strings.builder_make(context.temp_allocator)
		if doc.root != nil do tree_text(doc.root, &b)
		testing.expectf(t, strings.to_string(b) == c.want, "%s:\ngot:\n%s\nwant:\n%s", c.name, strings.to_string(b), c.want)
	}
}

@(private = "file")
Yaml_Error_Case :: struct {
	src:          string,
	kind:         yml.Error_Kind,
	line, column: int,
	message:      string, // must occur in the error's message
}

@(private = "file")
YAML_ERROR_CASES := [?]Yaml_Error_Case {
	// outside the subset
	{"a: &x 1\n", .Unsupported, 1, 4, "anchors"},
	{"a: *x\n", .Unsupported, 1, 4, "aliases"},
	{"a: !!str 1\n", .Unsupported, 1, 4, "tags"},
	{"a: [!foo b]\n", .Unsupported, 1, 5, "tags"},
	{"a:\n  <<: {b: 1}\n", .Unsupported, 2, 3, "merge keys"},
	{"? a\n: b\n", .Unsupported, 1, 1, "complex keys"},
	{"[a]: b\n", .Unsupported, 1, 1, "complex keys"},
	{"a: {[b]: c}\n", .Unsupported, 1, 5, "complex keys"},
	{"a: 1\n---\nb: 2\n", .Unsupported, 2, 1, "multi-document"},
	{"%YAML 1.1\n---\na: 1\n", .Unsupported, 1, 1, "directives"},
	{"a: [b: c]\n", .Unsupported, 1, 6, "a mapping inside a flow sequence"},
	{"a: {b}\n", .Unsupported, 1, 6, "without a value"},

	// duplicate keys
	{"a: 1\nb: 2\na: 3\n", .Duplicate_Key, 3, 1, `duplicate key "a" (first at line 1, column 1)`},
	{"a: {b: 1, 'b': 2}\n", .Duplicate_Key, 1, 11, `duplicate key "b"`},

	// not valid YAML (libyaml rejects each of these too)
	{"a: b: c\n", .Syntax, 1, 5, "a mapping cannot start on the line of its key"},
	{"a: - b\n", .Syntax, 1, 4, "a block sequence cannot start on the line of its key"},
	{"a:\n\t- b\n", .Syntax, 2, 1, "tab"},
	{"a: \"open\n", .Syntax, 1, 4, "unterminated quoted scalar"},
	{"a: [1, 2\n", .Syntax, 1, 4, "unterminated flow collection"},
	{"a: \"x\" y\n", .Syntax, 1, 8, `unexpected "y" after a value`},
	{"a: |x\n  b\n", .Syntax, 1, 5, "after the block scalar header"},
	{"a: \"\\q\"\n", .Syntax, 1, 5, `unknown escape \q`},
	{"a:\n  b: \"1\"\n   c: 2\n", .Syntax, 3, 4, "unexpected indentation"},

	// an implicit key in a flow collection and its : on two lines, which a
	// comment or a line break between them cannot join, as in libyaml
	{"meta: {\"id\"# comment\n : t}\nseq: []\n", .Syntax, 2, 2, "a : after a key must be on the line the key starts on"},
	{"a: {\"id\" # c\n : t}\n", .Syntax, 2, 2, "a : after a key must be on the line the key starts on"},
	{"a: {id\n : t}\n", .Syntax, 2, 2, "a : after a key must be on the line the key starts on"},
	{"a: {a\n b: c}\n", .Syntax, 2, 3, "a : after a key must be on the line the key starts on"},
	{"a: {\"x\n y\": t}\n", .Syntax, 2, 4, "a : after a key must be on the line the key starts on"},
	{"a: [x\n : t]\n", .Syntax, 2, 2, "a : after a key must be on the line the key starts on"},

	// escapes outside the Unicode scalar values, which wrapped when read
	// as a rune
	{"a: \"\\U00110000\"\n", .Syntax, 1, 5, `escape \U is not a valid character`},
	{"a: \"\\U80000000\"\n", .Syntax, 1, 5, `escape \U is not a valid character`},
	{"a: \"\\UFFFFFFFF\"\n", .Syntax, 1, 5, `escape \U is not a valid character`},
	{"a: \"\\uD800\"\n", .Syntax, 1, 5, `escape \u is not a valid character`},
	{"a: \"\\U0000DFFF\"\n", .Syntax, 1, 5, `escape \U is not a valid character`},

	// characters YAML does not allow, raw, anywhere in the source
	{"a: \"\x00\"\n", .Syntax, 1, 5, "control character U+0000 is not allowed"},
	{"a: \"\x01\"\n", .Syntax, 1, 5, "control character U+0001 is not allowed"},
	{"a: '\x7f'\n", .Syntax, 1, 5, "control character U+007F is not allowed"},
	{"a: \x01\n", .Syntax, 1, 4, "control character U+0001 is not allowed"},
	{"a: 1\n# \x1b\n", .Syntax, 2, 3, "control character U+001B is not allowed"},
	{"a: 1\r\n\xc3\xa9: \"\x08\"\r\n", .Syntax, 2, 5, "control character U+0008 is not allowed"},
	{"a: \xc2\x80\n", .Syntax, 1, 4, "character U+0080 is not allowed"},
	{"a: \xef\xbf\xbe\n", .Syntax, 1, 4, "character U+FFFE is not allowed"},
	{"a: \xff\n", .Syntax, 1, 4, "invalid UTF-8 (byte 0xff)"},
	{"a: \xc3\n", .Syntax, 1, 4, "invalid UTF-8 (byte 0xc3)"},
	{"a: \xc0\xaf\n", .Syntax, 1, 4, "invalid UTF-8 (byte 0xc0)"},
	{"a: \xed\xa0\x80\n", .Syntax, 1, 4, "invalid UTF-8 (byte 0xed)"},
	{"\xff\xfea\x00:\x00 \x001\x00", .Unsupported, 1, 1, "UTF-16 is not supported"},
	{"a: 1\n- b\n", .Syntax, 2, 1, "expected a key"},
}

@(test)
yaml_errors :: proc(t: ^testing.T) {
	for c in YAML_ERROR_CASES {
		doc: yml.Document
		defer yml.destroy_document(&doc)
		err := yml.parse(c.src, &doc)
		defer yml.destroy_error(&err)

		testing.expectf(
			t,
			err.kind == c.kind && err.line == c.line && err.column == c.column && strings.contains(err.message, c.message),
			"%q: got %v at %v:%v: %s; want %v at %v:%v: ...%s...",
			c.src, err.kind, err.line, err.column, err.message, c.kind, c.line, c.column, c.message)
		testing.expectf(t, doc.root == nil, "%q: root set after an error", c.src)
	}
}
