package yaml

import arn "../arena"
import "core:fmt"
import "core:mem"
import "core:strings"

// The subset of YAML that .ksy files use (decision record §7.1): block
// mappings and sequences, flow sequences and mappings, plain, single- and
// double-quoted scalars, literal (|) and folded (>) block scalars, and
// comments. Rejected as .Unsupported: anchors, aliases, tags, merge keys
// (<<), complex keys (? and collections as keys), directives and
// multi-document streams. Duplicate keys are rejected as .Duplicate_Key.
//
// Scalars are not interpreted: 0x21, yes and ~ all reach the caller as
// text, with the style they were written in.
Kind :: enum {
	Scalar,
	Map,
	Seq,
}

Style :: enum {
	Plain,
	Single_Quoted,
	Double_Quoted,
	Literal, // |
	Folded,  // >
}

// line and column are 1-based; the column counts characters, not bytes. A
// scalar's position is that of its first character (its quote or block
// indicator); an empty scalar is placed right after the : or - before it. A
// block collection's position is that of its first key or -, a flow
// collection's that of its bracket.
Node :: struct {
	kind:         Kind,
	line, column: int,
	style:        Style,   // Scalar only
	text:         string,  // Scalar only: its content, after unquoting and folding
	entries:      []Entry, // Map only, in order
	items:        []^Node, // Seq only, in order
}

// key is always a Scalar.
Entry :: struct {
	key, value: ^Node,
}

// A parsed document. Every node and string reachable from root is allocated
// in arena; root is nil for a stream with no document.
Document :: struct {
	root:  ^Node,
	arena: arn.Arena,
}

destroy_document :: proc(doc: ^Document) {
	arn.arena_destroy(&doc.arena)
	doc^ = {}
}

Error_Kind :: enum {
	None,
	Syntax,        // not valid YAML (or not read as libyaml reads it)
	Unsupported,   // valid YAML outside the subset
	Duplicate_Key, // a key that occurs twice in one mapping
}

Error :: struct {
	kind:         Error_Kind,
	line, column: int,    // 1-based
	message:      string, // owned (context.allocator); free with destroy_error
}

destroy_error :: proc(err: ^Error) {
	delete(err.message)
	err^ = {}
}

// Parses src into doc, which must be zero or destroyed. doc does not refer
// to src. On error doc may be partly filled; destroy it either way.
@(require_results)
parse :: proc(src: string, doc: ^Document) -> Error {
	assert(doc.arena.block == nil && doc.root == nil, "parse: doc must be zero or destroyed")
	root, err := parse_into(src, arn.arena_allocator(&doc.arena))
	doc.root = root
	return err
}

// Parses src as parse does, allocating every node and string with
// allocator, which must free them all at once (an arena): an error leaves
// what was allocated. root is nil for a stream with no document, and on
// error. The nodes do not refer to src: the parser reads a copy of it,
// made with allocator, which the text of a scalar is a slice of unless it
// has to be built.
@(require_results)
parse_into :: proc(src: string, allocator: mem.Allocator) -> (root: ^Node, err: Error) {
	p := Parser{src = strings.clone(src, allocator), line = 1, allocator = allocator}

	if strings.has_prefix(src, "\xef\xbb\xbf") do p.pos, p.line_start = 3, 3

	if skip_to_content(&p) {
		if peek(&p) == '%' && column(&p) == 0 {
			fail(&p, .Unsupported, p.pos, "directives (%%YAML, %%TAG) are not supported")
			return nil, p.err
		}
		if at_document_marker(&p, "---") {
			p.pos += 3
		}
		root = parse_node(&p, -1, .Top)
	}

	if p.err.kind == .None && skip_to_content(&p) {
		switch {
		case at_document_marker(&p, "..."):
			p.pos += 3
			if skip_to_content(&p) do fail(&p, .Unsupported, p.pos, "multi-document streams are not supported")
		case at_document_marker(&p, "---"):
			fail(&p, .Unsupported, p.pos, "multi-document streams are not supported")
		case:
			fail(&p, .Syntax, p.pos, "unexpected %s", describe(&p))
		}
	}

	if p.err.kind != .None do root = nil
	return root, p.err
}

@(private = "file")
Parser :: struct {
	src:        string,
	pos:        int,
	line:       int, // of pos, 1-based
	line_start: int, // offset of the first byte of pos's line
	allocator:  mem.Allocator,
	end:        Mark, // where the last scalar or flow collection ended
	err:        Error,
}

// Where a node is parsed: at the top of the document, as the value of a
// block mapping entry (after "key:"), or as an item of a block sequence
// (after "-").
@(private = "file")
Context :: enum {
	Top,
	Block_Value,
	Seq_Item,
}

// A position in the source: an offset, and its line and line start.
@(private = "file")
Mark :: struct {
	pos, line, line_start: int,
}

@(private = "file")
mark :: proc(p: ^Parser) -> Mark {
	return {p.pos, p.line, p.line_start}
}

@(private = "file")
reset :: proc(p: ^Parser, m: Mark) {
	p.pos, p.line, p.line_start = m.pos, m.line, m.line_start
}

// Records the first error, at offset pos of the current line; always
// returns nil.
@(private = "file")
fail :: proc(p: ^Parser, kind: Error_Kind, pos: int, format: string, args: ..any) -> ^Node {
	return fail_at(p, kind, {pos, p.line, p.line_start}, format, ..args)
}

@(private = "file")
fail_at :: proc(p: ^Parser, kind: Error_Kind, m: Mark, format: string, args: ..any) -> ^Node {
	if p.err.kind == .None {
		p.err = Error{kind = kind, line = m.line, column = char_column(p.src, m) + 1, message = fmt.aprintf(format, ..args)}
	}
	return nil
}

@(private = "file")
describe :: proc(p: ^Parser) -> string {
	if p.pos >= len(p.src) do return "end of input"
	return fmt.tprintf("%q", p.src[p.pos:p.pos + 1])
}

@(private = "file")
peek :: proc(p: ^Parser, k := 0) -> byte {
	i := p.pos + k
	return i < len(p.src) ? p.src[i] : 0
}

@(private = "file")
is_break :: proc(c: byte) -> bool {
	return c == '\n' || c == '\r'
}

@(private = "file")
is_blank :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t'
}

// Blank, a line break, or the end of input (0).
@(private = "file")
is_blankz :: proc(c: byte) -> bool {
	return is_blank(c) || is_break(c) || c == 0
}

@(private = "file")
is_flow_indicator :: proc(c: byte) -> bool {
	return c == ',' || c == '[' || c == ']' || c == '{' || c == '}'
}

// The 0-based column of m, in characters.
@(private = "file")
char_column :: proc(src: string, m: Mark) -> int {
	n := 0
	for i in m.line_start ..< m.pos {
		if src[i] & 0xc0 != 0x80 do n += 1
	}
	return n
}

@(private = "file")
column :: proc(p: ^Parser) -> int {
	return char_column(p.src, mark(p))
}

// Advances one byte, keeping line and line_start up to date. \r\n is one
// line break.
@(private = "file")
advance :: proc(p: ^Parser) {
	c := p.src[p.pos]
	p.pos += 1
	if c == '\n' || (c == '\r' && peek(p) != '\n') {
		p.line += 1
		p.line_start = p.pos
	}
}

// Skips a line break, \r\n counting as one.
@(private = "file")
skip_break :: proc(p: ^Parser) {
	if peek(p) == '\r' do advance(p)
	if peek(p) == '\n' do advance(p)
}

// Whether text, followed by a blank, a line break or the end, starts at
// the reader's position in column 0.
@(private = "file")
at_document_marker :: proc(p: ^Parser, text: string) -> bool {
	return p.pos == p.line_start && strings.has_prefix(p.src[p.pos:], text) && is_blankz(peek(p, 3))
}

// Skips blanks, comments and line breaks. Returns false at the end of
// input. A tab in the indentation of a line that has content is an error.
@(private = "file")
skip_to_content :: proc(p: ^Parser) -> bool {
	in_indent := p.pos == p.line_start
	for p.pos < len(p.src) {
		switch c := p.src[p.pos]; c {
		case ' ':
			advance(p)
		case '\t':
			if in_indent && !rest_of_line_empty(p) {
				fail(p, .Syntax, p.pos, "a tab character is not allowed in indentation")
				return false
			}
			advance(p)
		case '\n', '\r':
			skip_break(p)
			in_indent = true
		case '#':
			for p.pos < len(p.src) && !is_break(p.src[p.pos]) do advance(p)
		case:
			return p.err.kind == .None
		}
	}
	return false
}

// Whether only blanks, and perhaps a comment, remain on the current line.
@(private = "file")
rest_of_line_empty :: proc(p: ^Parser) -> bool {
	for i in p.pos ..< len(p.src) {
		c := p.src[i]
		if is_break(c) || c == '#' do return true
		if !is_blank(c) do return false
	}
	return true
}

@(private = "file")
new_node :: proc(p: ^Parser, kind: Kind, m: Mark) -> ^Node {
	n := new(Node, p.allocator)
	n^ = {kind = kind, line = m.line, column = char_column(p.src, m) + 1}
	return n
}

@(private = "file")
new_scalar :: proc(p: ^Parser, m: Mark, style: Style, text: string) -> ^Node {
	n := new_node(p, .Scalar, m)
	n.style = style
	n.text = text
	p.end = mark(p)
	return n
}

// Parses the node that follows an indicator (or starts the document). It
// must start in a column greater than indent, the column of the
// collection the indicator belongs to; the one exception is a block
// sequence that is the value of a mapping entry, which may start in the
// mapping's own column. Returns an empty plain scalar, placed at the
// reader's position, when there is no such node.
@(private = "file")
parse_node :: proc(p: ^Parser, indent: int, ctx: Context) -> ^Node {
	empty_at := mark(p)
	start_line := p.line

	if !skip_to_content(p) {
		if p.err.kind != .None do return nil
		reset(p, empty_at)
		return new_scalar(p, empty_at, .Plain, "")
	}

	same_line := p.line == start_line && ctx != .Top
	col := column(p)

	if at_document_marker(p, "---") || at_document_marker(p, "...") {
		reset(p, empty_at)
		return new_scalar(p, empty_at, .Plain, "")
	}
	if !same_line && col <= indent {
		if ctx == .Block_Value && col == indent && at_seq_entry(p) do return parse_block_seq(p, col)
		reset(p, empty_at)
		return new_scalar(p, empty_at, .Plain, "")
	}

	switch c := peek(p); c {
	case '&':
		return fail(p, .Unsupported, p.pos, "anchors are not supported")
	case '*':
		return fail(p, .Unsupported, p.pos, "aliases are not supported")
	case '!':
		return fail(p, .Unsupported, p.pos, "tags are not supported")
	case '%':
		if col == 0 do return fail(p, .Unsupported, p.pos, "directives (%%YAML, %%TAG) are not supported")
		return fail(p, .Syntax, p.pos, "a plain scalar cannot start with %%")
	case '@', '`':
		return fail(p, .Syntax, p.pos, "a plain scalar cannot start with %c", rune(c))
	case '?':
		if is_blankz(peek(p, 1)) do return fail(p, .Unsupported, p.pos, "complex keys (?) are not supported")
	case '-':
		if is_blankz(peek(p, 1)) {
			if same_line && ctx == .Block_Value do return fail(p, .Syntax, p.pos, "a block sequence cannot start on the line of its key")
			return parse_block_seq(p, col)
		}
	case '|', '>':
		return parse_block_scalar(p, indent)
	case '[', '{':
		start := mark(p)
		node := parse_flow(p)
		if node != nil && followed_by_colon(p) {
			return fail_at(p, .Unsupported, start, "complex keys (collections as keys) are not supported")
		}
		return node
	case ',', ']', '}', '#':
		return fail(p, .Syntax, p.pos, "unexpected %s", describe(p))
	}

	// a scalar, or the first key of a block mapping
	start := mark(p)
	scalar: ^Node
	multiline: bool
	if c := peek(p); c == '"' || c == '\'' {
		scalar = parse_quoted(p)
		multiline = p.line != start.line
	} else {
		scalar, multiline = parse_plain(p, indent, false)
	}
	if scalar == nil do return nil

	if !followed_by_colon(p) do return scalar

	if multiline do return fail_at(p, .Syntax, start, "a key must be on one line")
	if same_line && ctx == .Block_Value do return fail(p, .Syntax, p.pos, "a mapping cannot start on the line of its key")
	return parse_block_map(p, col, scalar)
}

// Whether a : followed by a blank, a line break or the end comes next on
// the current line, after blanks. Leaves the reader at the : if so.
@(private = "file")
followed_by_colon :: proc(p: ^Parser) -> bool {
	m := mark(p)
	for is_blank(peek(p)) do advance(p)
	if peek(p) == ':' && is_blankz(peek(p, 1)) do return true
	reset(p, m)
	return false
}

@(private = "file")
at_seq_entry :: proc(p: ^Parser) -> bool {
	return peek(p) == '-' && is_blankz(peek(p, 1))
}

// Checks that the reader, at content, is not on the line where the last
// scalar or flow collection ended: nothing but blanks and a comment may
// follow one on its line. A block scalar ends at the start of a line.
@(private = "file")
expect_line_end :: proc(p: ^Parser) -> bool {
	if p.line == p.end.line && p.end.pos != p.end.line_start {
		fail(p, .Syntax, p.pos, "unexpected %s after a value", describe(p))
		return false
	}
	return true
}

// A block mapping whose keys are in column col, starting at its first key,
// with the reader at the : after it.
@(private = "file")
parse_block_map :: proc(p: ^Parser, col: int, first_key: ^Node) -> ^Node {
	node := new_node(p, .Map, {})
	node.line, node.column = first_key.line, first_key.column
	entries := make([dynamic]Entry, p.allocator)

	key := first_key
	for {
		if !check_key(p, entries[:], key) do return nil
		advance(p) // the :
		value := parse_node(p, col, .Block_Value)
		if value == nil do return nil
		append(&entries, Entry{key, value})

		if !skip_to_content(p) do break
		if !expect_line_end(p) do return nil

		c := column(p)
		if c < col || at_document_marker(p, "---") || at_document_marker(p, "...") do break
		if c > col do return fail(p, .Syntax, p.pos, "unexpected indentation")

		key = parse_key(p)
		if key == nil do return nil
	}

	if p.err.kind != .None do return nil
	node.entries = entries[:]
	return node
}

// A block mapping key: a one-line plain or quoted scalar, followed by :.
@(private = "file")
parse_key :: proc(p: ^Parser) -> ^Node {
	start := mark(p)
	key: ^Node
	switch peek(p) {
	case '?':
		if is_blankz(peek(p, 1)) do return fail(p, .Unsupported, p.pos, "complex keys (?) are not supported")
	case '[', '{':
		return fail(p, .Unsupported, p.pos, "complex keys (collections as keys) are not supported")
	case '&':
		return fail(p, .Unsupported, p.pos, "anchors are not supported")
	case '*':
		return fail(p, .Unsupported, p.pos, "aliases are not supported")
	case '!':
		return fail(p, .Unsupported, p.pos, "tags are not supported")
	case '-':
		if is_blankz(peek(p, 1)) do return fail(p, .Syntax, p.pos, "expected a key, found a sequence entry")
	case '|', '>', ',', ']', '}', '@', '`', '%':
		return fail(p, .Syntax, p.pos, "expected a key, found %s", describe(p))
	}

	if c := peek(p); c == '"' || c == '\'' {
		key = parse_quoted(p)
	} else {
		key, _ = parse_plain(p, column(p), false)
	}
	if key == nil do return nil

	if p.line != start.line do return fail_at(p, .Syntax, start, "a key must be on one line")
	if !followed_by_colon(p) do return fail_at(p, .Syntax, start, "expected : after a key")
	return key
}

// Rejects a merge key, and a key already in entries.
@(private = "file")
check_key :: proc(p: ^Parser, entries: []Entry, key: ^Node) -> bool {
	if key.style == .Plain && key.text == "<<" {
		fail_at_node(p, .Unsupported, key, "merge keys (<<) are not supported")
		return false
	}
	for e in entries {
		if e.key.text == key.text {
			fail_at_node(p, .Duplicate_Key, key, "duplicate key %q (first at line %v, column %v)", key.text, e.key.line, e.key.column)
			return false
		}
	}
	return true
}

@(private = "file")
fail_at_node :: proc(p: ^Parser, kind: Error_Kind, n: ^Node, format: string, args: ..any) {
	if p.err.kind == .None {
		p.err = Error{kind = kind, line = n.line, column = n.column, message = fmt.aprintf(format, ..args)}
	}
}

// A block sequence whose entries are in column col, with the reader at the
// first -.
@(private = "file")
parse_block_seq :: proc(p: ^Parser, col: int) -> ^Node {
	node := new_node(p, .Seq, mark(p))
	items := make([dynamic]^Node, p.allocator)

	for {
		advance(p) // the -
		item := parse_node(p, col, .Seq_Item)
		if item == nil do return nil
		append(&items, item)

		if !skip_to_content(p) do break
		if !expect_line_end(p) do return nil

		c := column(p)
		if c < col || !at_seq_entry(p) do break
		if c > col do return fail(p, .Syntax, p.pos, "unexpected indentation")
	}

	if p.err.kind != .None do return nil
	node.items = items[:]
	return node
}

// A plain scalar. indent is the column of the enclosing block collection:
// in block context a continuation line must be indented further. In flow
// context the scalar also ends at , [ ] { }, and at : before one of them.
// multiline reports whether it spans more than one line.
@(private = "file")
parse_plain :: proc(p: ^Parser, indent: int, flow: bool) -> (node: ^Node, multiline: bool) {
	start := mark(p)
	// until a line break is folded, the text is the source from start to end
	b: strings.Builder
	folded := false

	// blanks and line breaks seen since the last character of the scalar
	spaces_from, spaces_to := 0, 0
	breaks := 0
	pending := false
	end := mark(p)

	scan: for {
		if at_document_marker(p, "---") || at_document_marker(p, "...") do break
		if peek(p) == '#' do break

		for !is_blankz(peek(p)) {
			c := peek(p)
			if c == ':' && (is_blankz(peek(p, 1)) || (flow && is_flow_indicator(peek(p, 1)))) do break scan
			if flow && is_flow_indicator(c) do break scan

			if pending {
				if breaks > 0 && !folded {
					b = strings.builder_make(p.allocator)
					strings.write_string(&b, p.src[start.pos:end.pos])
					folded = true
				}
				if folded {
					switch breaks {
					case 0:
						strings.write_string(&b, p.src[spaces_from:spaces_to])
					case 1:
						strings.write_byte(&b, ' ')
					case:
						for _ in 1 ..< breaks do strings.write_byte(&b, '\n')
					}
				}
				pending, breaks = false, 0
			}
			if folded do strings.write_byte(&b, c)
			advance(p)
			end = mark(p)
		}

		if !is_blank(peek(p)) && !is_break(peek(p)) do break

		// blanks and line breaks
		spaces_from = p.pos
		for is_blank(peek(p)) || is_break(peek(p)) {
			if is_break(peek(p)) {
				skip_break(p)
				breaks += 1
				spaces_from = p.pos
			} else {
				if breaks > 0 && peek(p) == '\t' && column(p) <= indent {
					fail(p, .Syntax, p.pos, "a tab character is not allowed in indentation")
					return nil, false
				}
				advance(p)
			}
		}
		spaces_to = p.pos
		pending = true

		if !flow && breaks > 0 && column(p) <= indent do break
		if p.pos >= len(p.src) do break
	}

	// leave the reader right after the last character
	reset(p, end)
	text := folded ? strings.to_string(b) : p.src[start.pos:end.pos]
	return new_scalar(p, start, .Plain, text), end.line != start.line
}

// A single- or double-quoted scalar. Line breaks fold as in a plain
// scalar; a double-quoted scalar may also escape them.
@(private = "file")
parse_quoted :: proc(p: ^Parser) -> ^Node {
	start := mark(p)
	quote := peek(p)
	style: Style = quote == '"' ? .Double_Quoted : .Single_Quoted
	advance(p)
	// until an escape or a folded line break, the text is the source from
	// from to the reader; then it is built in b
	from := p.pos
	b: strings.Builder
	built := false

	for {
		if p.pos >= len(p.src) do return fail_at(p, .Syntax, start, "unterminated quoted scalar")
		if at_document_marker(p, "---") || at_document_marker(p, "...") {
			return fail_at(p, .Syntax, start, "a document marker inside a quoted scalar")
		}

		// the characters of one line
		for p.pos < len(p.src) && !is_blank(peek(p)) && !is_break(peek(p)) {
			c := peek(p)
			if quote == '\'' && c == '\'' {
				if peek(p, 1) != '\'' do break
				build_from(p, &b, &built, from)
				strings.write_byte(&b, '\'')
				advance(p)
				advance(p)
			} else if c == quote {
				break
			} else if quote == '"' && c == '\\' {
				build_from(p, &b, &built, from)
				if is_break(peek(p, 1)) {
					// an escaped line break: join the lines with nothing
					advance(p)
					skip_break(p)
					for is_blank(peek(p)) do advance(p)
					continue
				}
				if !write_escape(p, &b) do return nil
			} else {
				if built do strings.write_byte(&b, c)
				advance(p)
			}
		}

		if peek(p) == quote {
			text := built ? strings.to_string(b) : p.src[from:p.pos]
			advance(p)
			return new_scalar(p, start, style, text)
		}

		// blanks and line breaks: kept within a line, folded across lines
		spaces_from := p.pos
		for is_blank(peek(p)) do advance(p)
		if !is_break(peek(p)) {
			if built do strings.write_string(&b, p.src[spaces_from:p.pos])
			continue
		}

		if !built {
			b = strings.builder_make(p.allocator)
			strings.write_string(&b, p.src[from:spaces_from])
			built = true
		}
		breaks := 0
		for is_blank(peek(p)) || is_break(peek(p)) {
			if is_break(peek(p)) {
				skip_break(p)
				breaks += 1
			} else {
				advance(p)
			}
		}
		if breaks == 1 {
			strings.write_byte(&b, ' ')
		} else {
			for _ in 1 ..< breaks do strings.write_byte(&b, '\n')
		}
	}
}

// Starts building a quoted scalar's text in b, from the source from from to
// the reader, unless it is built already.
@(private = "file")
build_from :: proc(p: ^Parser, b: ^strings.Builder, built: ^bool, from: int) {
	if built^ do return
	b^ = strings.builder_make(p.allocator)
	strings.write_string(b, p.src[from:p.pos])
	built^ = true
}

// Writes the character a backslash escape stands for, with the reader at
// the backslash.
@(private = "file")
write_escape :: proc(p: ^Parser, b: ^strings.Builder) -> bool {
	at := p.pos
	advance(p)
	c := peek(p)
	if p.pos >= len(p.src) {
		fail(p, .Syntax, at, "unterminated escape")
		return false
	}
	advance(p)

	digits := 0
	switch c {
	case '0':  strings.write_byte(b, 0)
	case 'a':  strings.write_byte(b, 0x07)
	case 'b':  strings.write_byte(b, 0x08)
	case 't', '\t': strings.write_byte(b, '\t')
	case 'n':  strings.write_byte(b, '\n')
	case 'v':  strings.write_byte(b, 0x0b)
	case 'f':  strings.write_byte(b, 0x0c)
	case 'r':  strings.write_byte(b, '\r')
	case 'e':  strings.write_byte(b, 0x1b)
	case ' ':  strings.write_byte(b, ' ')
	case '"':  strings.write_byte(b, '"')
	case '/':  strings.write_byte(b, '/')
	case '\\': strings.write_byte(b, '\\')
	case 'N':  strings.write_rune(b, 0x85)
	case '_':  strings.write_rune(b, 0xa0)
	case 'L':  strings.write_rune(b, 0x2028)
	case 'P':  strings.write_rune(b, 0x2029)
	case 'x':  digits = 2
	case 'u':  digits = 4
	case 'U':  digits = 8
	case:
		fail(p, .Syntax, at, "unknown escape \\%c", rune(c))
		return false
	}

	if digits > 0 {
		r: rune
		for _ in 0 ..< digits {
			d := peek(p)
			v: rune
			switch d {
			case '0' ..= '9': v = rune(d - '0')
			case 'a' ..= 'f': v = rune(d - 'a' + 10)
			case 'A' ..= 'F': v = rune(d - 'A' + 10)
			case:
				fail(p, .Syntax, at, "\\%c needs %v hexadecimal digits", rune(c), digits)
				return false
			}
			r = r * 16 + v
			advance(p)
		}
		if r > 0x10ffff || (r >= 0xd800 && r <= 0xdfff) {
			fail(p, .Syntax, at, "escape \\%c is not a valid character", rune(c))
			return false
		}
		strings.write_rune(b, r)
	}
	return true
}

// A literal (|) or folded (>) block scalar, with the reader at the
// indicator. indent is the column of the enclosing block collection (-1 at
// the top): the content is indented further, by the explicit indentation
// indicator when there is one.
@(private = "file")
parse_block_scalar :: proc(p: ^Parser, indent: int) -> ^Node {
	start := mark(p)
	literal := peek(p) == '|'
	advance(p)

	Chomp :: enum {
		Clip,
		Strip,
		Keep,
	}
	chomp := Chomp.Clip
	increment := 0
	for _ in 0 ..< 2 {
		switch c := peek(p); c {
		case '+', '-':
			if chomp != .Clip do return fail(p, .Syntax, p.pos, "two chomping indicators")
			chomp = c == '+' ? .Keep : .Strip
			advance(p)
		case '1' ..= '9':
			if increment != 0 do return fail(p, .Syntax, p.pos, "two indentation indicators")
			increment = int(c - '0')
			advance(p)
		case '0':
			return fail(p, .Syntax, p.pos, "the indentation indicator must be 1 to 9")
		}
	}

	for is_blank(peek(p)) do advance(p)
	if peek(p) == '#' && is_blank(p.src[p.pos - 1]) {
		for p.pos < len(p.src) && !is_break(peek(p)) do advance(p)
	}
	if p.pos < len(p.src) && !is_break(peek(p)) {
		return fail(p, .Syntax, p.pos, "expected a comment or a line break after the block scalar header")
	}
	skip_break(p)

	content_indent := 0
	if increment > 0 do content_indent = indent >= 0 ? indent + increment : increment

	b := strings.builder_make(p.allocator)
	leading_break, trailing_breaks := 0, 0 // line breaks not yet written
	if !block_scalar_breaks(p, &content_indent, &trailing_breaks, indent) do return nil

	leading_blank := false
	for column(p) == content_indent && p.pos < len(p.src) {
		trailing_blank := is_blank(peek(p))

		if !literal && leading_break == 1 && !leading_blank && !trailing_blank {
			if trailing_breaks == 0 do strings.write_byte(&b, ' ')
		} else {
			for _ in 0 ..< leading_break do strings.write_byte(&b, '\n')
		}
		leading_break = 0
		for _ in 0 ..< trailing_breaks do strings.write_byte(&b, '\n')
		trailing_breaks = 0

		leading_blank = is_blank(peek(p))

		from := p.pos
		for p.pos < len(p.src) && !is_break(peek(p)) do advance(p)
		strings.write_string(&b, p.src[from:p.pos])

		if p.pos < len(p.src) {
			skip_break(p)
			leading_break = 1
		}

		if !block_scalar_breaks(p, &content_indent, &trailing_breaks, indent) do return nil
	}

	// leave the reader at the start of the line that ends the scalar, so that
	// the scalar is seen to end there
	if strings.trim_left(p.src[p.line_start:p.pos], " ") == "" do p.pos = p.line_start

	if chomp != .Strip {
		for _ in 0 ..< leading_break do strings.write_byte(&b, '\n')
	}
	if chomp == .Keep {
		for _ in 0 ..< trailing_breaks do strings.write_byte(&b, '\n')
	}

	return new_scalar(p, start, literal ? .Literal : .Folded, strings.to_string(b))
}

// Skips the indentation and the empty lines before a block scalar's next
// line of content, counting the line breaks in breaks. When content_indent
// is 0 it is set from the lines skipped and the first line of content.
@(private = "file")
block_scalar_breaks :: proc(p: ^Parser, content_indent: ^int, breaks: ^int, indent: int) -> bool {
	max_indent := 0
	for {
		for (content_indent^ == 0 || column(p) < content_indent^) && peek(p) == ' ' do advance(p)
		max_indent = max(max_indent, column(p))

		if (content_indent^ == 0 || column(p) < content_indent^) && peek(p) == '\t' {
			fail(p, .Syntax, p.pos, "a tab character is not allowed in indentation")
			return false
		}
		if !is_break(peek(p)) do break

		skip_break(p)
		breaks^ += 1
	}

	if content_indent^ == 0 {
		content_indent^ = max(max_indent, indent + 1, 1)
	}
	return true
}

// A flow sequence or mapping, with the reader at its bracket.
@(private = "file")
parse_flow :: proc(p: ^Parser) -> ^Node {
	is_map := peek(p) == '{'
	close: byte = is_map ? '}' : ']'
	node := new_node(p, is_map ? .Map : .Seq, mark(p))
	advance(p)

	entries := make([dynamic]Entry, p.allocator)
	items := make([dynamic]^Node, p.allocator)

	for {
		if !skip_flow_space(p) do return nil
		if peek(p) == close {
			advance(p)
			break
		}

		if is_map {
			key := parse_flow_node(p)
			if key == nil do return nil
			if key.kind != .Scalar do return fail_at_node_nil(p, .Unsupported, key, "complex keys (collections as keys) are not supported")
			if !check_key(p, entries[:], key) do return nil

			if !skip_flow_space(p) do return nil
			if peek(p) != ':' do return fail(p, .Unsupported, p.pos, "a flow mapping entry without a value is not supported")
			advance(p)

			// libyaml places an empty value at the token after it
			if !skip_flow_space(p) do return nil
			value: ^Node
			if c := peek(p); c == ',' || c == '}' {
				value = new_scalar(p, mark(p), .Plain, "")
			} else {
				value = parse_flow_node(p)
				if value == nil do return nil
			}
			append(&entries, Entry{key, value})
		} else {
			item := parse_flow_node(p)
			if item == nil do return nil
			if !skip_flow_space(p) do return nil
			if peek(p) == ':' do return fail(p, .Unsupported, p.pos, "a mapping inside a flow sequence is not supported")
			append(&items, item)
		}

		if !skip_flow_space(p) do return nil
		switch peek(p) {
		case ',':
			advance(p)
		case close:
		case:
			if p.pos >= len(p.src) do return fail_at_node_nil(p, .Syntax, node, "unterminated flow collection")
			return fail(p, .Syntax, p.pos, "expected , or %c, found %s", rune(close), describe(p))
		}
	}

	if is_map {
		node.entries = entries[:]
	} else {
		node.items = items[:]
	}
	p.end = mark(p)
	return node
}

@(private = "file")
fail_at_node_nil :: proc(p: ^Parser, kind: Error_Kind, n: ^Node, format: string, args: ..any) -> ^Node {
	fail_at_node(p, kind, n, format, ..args)
	return nil
}

@(private = "file")
skip_flow_space :: proc(p: ^Parser) -> bool {
	for p.pos < len(p.src) {
		c := peek(p)
		if c == '#' && (p.pos == p.line_start || is_blank(p.src[p.pos - 1]) || is_break(p.src[p.pos - 1])) {
			for p.pos < len(p.src) && !is_break(peek(p)) do advance(p)
		} else if is_blank(c) || is_break(c) {
			advance(p)
		} else {
			break
		}
	}
	if at_document_marker(p, "---") || at_document_marker(p, "...") {
		fail(p, .Syntax, p.pos, "a document marker inside a flow collection")
		return false
	}
	return true
}

@(private = "file")
parse_flow_node :: proc(p: ^Parser) -> ^Node {
	switch c := peek(p); c {
	case '[', '{':
		return parse_flow(p)
	case '"', '\'':
		return parse_quoted(p)
	case '&':
		return fail(p, .Unsupported, p.pos, "anchors are not supported")
	case '*':
		return fail(p, .Unsupported, p.pos, "aliases are not supported")
	case '!':
		return fail(p, .Unsupported, p.pos, "tags are not supported")
	case '?':
		if is_blankz(peek(p, 1)) do return fail(p, .Unsupported, p.pos, "complex keys (?) are not supported")
	case '|', '>', ',', ']', '}', '#', '@', '`', '%', ':':
		return fail(p, .Syntax, p.pos, "unexpected %s", describe(p))
	case '-':
		if is_blankz(peek(p, 1)) || is_flow_indicator(peek(p, 1)) do return fail(p, .Syntax, p.pos, "unexpected -")
	case 0:
		return fail(p, .Syntax, p.pos, "unterminated flow collection")
	}
	node, _ := parse_plain(p, -1, true)
	return node
}
