package expression

import mdata "../metadata"
import "core:fmt"
import "core:mem"
import "core:strings"

Error_Kind :: enum {
	None,
	Syntax,      // not a valid expression
	Unsupported, // valid Kaitai, but outside the supported subset
	Invalid,     // a name that does not resolve, or a type mismatch
}

Error :: struct {
	kind:    Error_Kind,
	offset:  int,    // byte offset in the expression's text; -1 when there is none
	message: string, // owned (context.allocator); free with destroy_error
}

destroy_error :: proc(err: ^Error) {
	delete(err.message)
	err^ = {}
}

// Parses text into an expression with only syntax variants, allocated with
// allocator; it does not refer to text. Kaitai's operators and their precedence, loosest first:
//   ?:  or  and  not  comparisons  |  ^  &  << >>  + -  * / %  unary - ~ +  .
// Every binary operator is left-associative, except that ?: is
// right-associative and a comparison cannot be an operand of another
// comparison. Integer literals are decimal, 0x hex, 0b binary or 0o octal,
// with _ allowed between digits; string literals are as String_Literal
// describes. Float and array literals, method calls and casts are rejected
// as Unsupported.
@(require_results)
parse :: proc(text: string, allocator: mem.Allocator) -> (e: ^mdata.Expr, err: Error) {
	p := Parser{text = text, allocator = allocator}
	defer if p.err.kind != .None do e = nil

	if !next(&p) do return nil, p.err
	e = parse_expr(&p, 0) or_else nil
	if e != nil && p.tok.kind != .EOF {
		fail(&p, .Syntax, p.tok.offset, "unexpected %s", describe(p.tok))
	}
	return e, p.err
}

// Parses text as a list of expressions separated by commas, each as parse
// parses one: the arguments of a type, t(a, b). Empty text is no
// expressions.
@(require_results)
parse_list :: proc(text: string, allocator: mem.Allocator) -> (list: []^mdata.Expr, err: Error) {
	p := Parser{text = text, allocator = allocator}
	defer if p.err.kind != .None do list = nil

	if !next(&p) do return nil, p.err
	items := make([dynamic]^mdata.Expr, allocator)
	for p.tok.kind != .EOF {
		e := parse_expr(&p, 0) or_break
		append(&items, e)
		if p.tok.kind == .EOF do break
		if p.tok.kind != .Comma {
			fail(&p, .Syntax, p.tok.offset, "unexpected %s", describe(p.tok))
			break
		}
		if !next(&p) do break
		if p.tok.kind == .EOF do fail(&p, .Syntax, p.tok.offset, "expected an expression after ,")
	}
	return items[:], p.err
}

@(private = "file")
Token_Kind :: enum {
	EOF,
	Int,
	String,
	Ident,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Shl,
	Shr,
	Amp,
	Pipe,
	Caret,
	Tilde,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
	Question,
	Colon,
	Colon_Colon,
	Dot,
	Comma,
	L_Paren,
	R_Paren,
	L_Bracket,
	R_Bracket,
}

@(private = "file")
Token :: struct {
	kind:   Token_Kind,
	offset: int,
	text:   string,
	value:  int,    // Int only
	str:    string, // String only: its value, allocated with the parser's allocator
}

@(private = "file")
Parser :: struct {
	text:      string,
	pos:       int, // of the next token
	tok:       Token,
	allocator: mem.Allocator,
	err:       Error,
}

// Records the first error; always returns false.
@(private = "file")
fail :: proc(p: ^Parser, kind: Error_Kind, offset: int, format: string, args: ..any) -> bool {
	if p.err.kind == .None {
		p.err = Error{kind = kind, offset = offset, message = fmt.aprintf(format, ..args)}
	}
	return false
}

@(private = "file")
describe :: proc(t: Token) -> string {
	return t.kind == .EOF ? "end of expression" : t.text
}

@(private = "file")
is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_ident_start :: proc(c: byte) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// Reads the next token into p.tok.
@(private = "file")
next :: proc(p: ^Parser) -> bool {
	for p.pos < len(p.text) && (p.text[p.pos] == ' ' || p.text[p.pos] == '\t' || p.text[p.pos] == '\n' || p.text[p.pos] == '\r') {
		p.pos += 1
	}

	start := p.pos
	if start == len(p.text) {
		p.tok = Token{kind = .EOF, offset = start}
		return true
	}

	c := p.text[start]
	kind: Token_Kind
	n := 1

	switch {
	case is_digit(c):
		return lex_int(p)
	case is_ident_start(c):
		for start + n < len(p.text) && (is_ident_start(p.text[start + n]) || is_digit(p.text[start + n])) do n += 1
		kind = .Ident
	case c == '\'' || c == '"':
		return lex_string(p)
	case:
		two := p.text[start:min(start + 2, len(p.text))]
		switch two {
		case "<<":
			kind, n = .Shl, 2
		case ">>":
			kind, n = .Shr, 2
		case "==":
			kind, n = .Eq, 2
		case "!=":
			kind, n = .Ne, 2
		case "<=":
			kind, n = .Le, 2
		case ">=":
			kind, n = .Ge, 2
		case "::":
			kind, n = .Colon_Colon, 2
		case:
			switch c {
			case '+':
				kind = .Plus
			case '-':
				kind = .Minus
			case '*':
				kind = .Star
			case '/':
				kind = .Slash
			case '%':
				kind = .Percent
			case '&':
				kind = .Amp
			case '|':
				kind = .Pipe
			case '^':
				kind = .Caret
			case '~':
				kind = .Tilde
			case '<':
				kind = .Lt
			case '>':
				kind = .Gt
			case '?':
				kind = .Question
			case ':':
				kind = .Colon
			case '.':
				kind = .Dot
			case ',':
				kind = .Comma
			case '(':
				kind = .L_Paren
			case ')':
				kind = .R_Paren
			case '[':
				kind = .L_Bracket
			case ']':
				kind = .R_Bracket
			case:
				return fail(p, .Syntax, start, "unexpected character %q", rune(c))
			}
		}
	}

	p.pos = start + n
	p.tok = Token{kind = kind, offset = start, text = p.text[start:p.pos]}
	return true
}

// A string literal at p.pos, which is a quote: '...' as it is, "..." with
// its escapes replaced (metadata.String_Literal).
@(private = "file")
lex_string :: proc(p: ^Parser) -> bool {
	start := p.pos
	quote := p.text[start]
	b := strings.builder_make(p.allocator)
	i := start + 1
	for {
		if i >= len(p.text) do return fail(p, .Syntax, start, "unterminated string literal")
		c := p.text[i]
		if c == quote do break
		if c != '\\' || quote == '\'' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		if i + 1 >= len(p.text) do return fail(p, .Syntax, start, "unterminated string literal")
		e := p.text[i + 1]
		i += 2
		switch e {
		case 'a':
			strings.write_byte(&b, 0x07)
		case 'b':
			strings.write_byte(&b, 0x08)
		case 't':
			strings.write_byte(&b, '\t')
		case 'n':
			strings.write_byte(&b, '\n')
		case 'v':
			strings.write_byte(&b, 0x0b)
		case 'f':
			strings.write_byte(&b, 0x0c)
		case 'r':
			strings.write_byte(&b, '\r')
		case 'e':
			strings.write_byte(&b, 0x1b)
		case '"', '\'', '\\':
			strings.write_byte(&b, e)
		case '0' ..= '7':
			n := int(e - '0')
			for k := 0; k < 2 && i < len(p.text) && p.text[i] >= '0' && p.text[i] <= '7'; k += 1 {
				n = n * 8 + int(p.text[i] - '0')
				i += 1
			}
			if n > 0xff do return fail(p, .Syntax, i - 4, "octal escape \\%s is above \\377", p.text[i - 3:i])
			strings.write_byte(&b, byte(n))
		case 'u':
			n := 0
			for k in 0 ..< 4 {
				d := i + k < len(p.text) ? hex_digit(p.text[i + k]) : -1
				if d < 0 do return fail(p, .Syntax, i - 2, "\\u needs four hex digits")
				n = n * 16 + d
			}
			i += 4
			strings.write_rune(&b, rune(n))
		case:
			return fail(p, .Syntax, i - 2, "unknown escape \\%c", rune(e))
		}
	}
	p.pos = i + 1
	p.tok = Token{kind = .String, offset = start, text = p.text[start:p.pos], str = strings.to_string(b)}
	return true
}

// The value of hex digit c, or -1 when it is not one.
@(private = "file")
hex_digit :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// An integer literal at p.pos, which is a digit.
@(private = "file")
lex_int :: proc(p: ^Parser) -> bool {
	start := p.pos
	base := 10
	digits := start
	if p.text[start] == '0' && start + 1 < len(p.text) {
		switch p.text[start + 1] {
		case 'x', 'X':
			base = 16
		case 'b', 'B':
			base = 2
		case 'o', 'O':
			base = 8
		}
		if base != 10 do digits += 2
	}

	end := digits
	for end < len(p.text) && (is_ident_start(p.text[end]) || is_digit(p.text[end])) do end += 1
	// 1.5 and 1. are floats; 1.to_s is a method of 1
	if end < len(p.text) && base == 10 && p.text[end] == '.' && (end + 1 == len(p.text) || !is_ident_start(p.text[end + 1])) {
		return fail(p, .Unsupported, start, "float literals are not supported")
	}

	text := p.text[start:end]
	value: u64
	n := 0 // digits seen
	for i in digits ..< end {
		c := p.text[i]
		if c == '_' && i > digits && p.text[i - 1] != '_' do continue

		d := 99
		switch c {
		case '0' ..= '9':
			d = int(c - '0')
		case 'a' ..= 'f':
			d = int(c - 'a') + 10
		case 'A' ..= 'F':
			d = int(c - 'A') + 10
		}
		if d >= base do return fail(p, .Syntax, start, "invalid integer literal %s", text)

		if value > (u64(max(int)) - u64(d)) / u64(base) {
			return fail(p, .Syntax, start, "integer literal %s is too large", text)
		}
		value = value * u64(base) + u64(d)
		n += 1
	}
	if n == 0 || p.text[end - 1] == '_' do return fail(p, .Syntax, start, "invalid integer literal %s", text)
	if base == 10 && n > 1 && p.text[start] == '0' do return fail(p, .Syntax, start, "invalid integer literal %s (use 0o for octal)", text)

	p.pos = end
	p.tok = Token{kind = .Int, offset = start, text = text, value = int(value)}
	return true
}

// Binding powers, loosest first.
@(private = "file")
BP_TERNARY :: 1
@(private = "file")
BP_OR :: 2
@(private = "file")
BP_AND :: 3
@(private = "file")
BP_NOT :: 4
@(private = "file")
BP_COMPARE :: 5
@(private = "file")
BP_UNARY :: 12

@(private = "file")
Infix :: struct {
	op: mdata.Binary_Op,
	bp: int,
}

// The binary operator at the current token, if it is one.
@(private = "file")
infix :: proc(p: ^Parser) -> (Infix, bool) {
	#partial switch p.tok.kind {
	case .Ident:
		switch p.tok.text {
		case "or":
			return {.Logical_Or, BP_OR}, true
		case "and":
			return {.Logical_And, BP_AND}, true
		}
	case .Eq:
		return {.Eq, BP_COMPARE}, true
	case .Ne:
		return {.Ne, BP_COMPARE}, true
	case .Lt:
		return {.Lt, BP_COMPARE}, true
	case .Le:
		return {.Le, BP_COMPARE}, true
	case .Gt:
		return {.Gt, BP_COMPARE}, true
	case .Ge:
		return {.Ge, BP_COMPARE}, true
	case .Pipe:
		return {.Or, 6}, true
	case .Caret:
		return {.Xor, 7}, true
	case .Amp:
		return {.And, 8}, true
	case .Shl:
		return {.Shl, 9}, true
	case .Shr:
		return {.Shr, 9}, true
	case .Plus:
		return {.Add, 10}, true
	case .Minus:
		return {.Sub, 10}, true
	case .Star:
		return {.Mul, 11}, true
	case .Slash:
		return {.Div, 11}, true
	case .Percent:
		return {.Mod, 11}, true
	}
	return {}, false
}

@(private = "file")
new_expr :: proc(p: ^Parser, offset: int, variant: mdata.Expr_Variant) -> ^mdata.Expr {
	e := new(mdata.Expr, p.allocator)
	e^ = {offset = offset, variant = variant}
	return e
}

// An expression whose operators all bind at least as tightly as min_bp.
@(private = "file")
parse_expr :: proc(p: ^Parser, min_bp: int) -> (left: ^mdata.Expr, ok: bool) {
	left = parse_prefix(p, min_bp) or_return

	for {
		if p.tok.kind == .Question {
			if BP_TERNARY < min_bp do break
			offset := p.tok.offset
			next(p) or_return
			then := parse_expr(p, 0) or_return
			if p.tok.kind != .Colon do return nil, fail(p, .Syntax, p.tok.offset, "expected : in ?:, found %s", describe(p.tok))
			next(p) or_return
			otherwise := parse_expr(p, BP_TERNARY) or_return
			left = new_expr(p, offset, mdata.Ternary{left, then, otherwise})
			continue
		}

		op, is_infix := infix(p)
		if !is_infix || op.bp < min_bp do break

		offset := p.tok.offset
		next(p) or_return
		right := parse_expr(p, op.bp + 1) or_return
		left = new_expr(p, offset, mdata.Binary{op.op, left, right})

		if op.bp == BP_COMPARE {
			if next_op, chained := infix(p); chained && next_op.bp == BP_COMPARE {
				return nil, fail(p, .Syntax, p.tok.offset, "comparisons cannot be chained")
			}
		}
	}

	return left, true
}

// A unary operator and its operand, or a primary expression.
@(private = "file")
parse_prefix :: proc(p: ^Parser, min_bp: int) -> (e: ^mdata.Expr, ok: bool) {
	offset := p.tok.offset
	op: mdata.Unary_Op
	bp: int

	#partial switch p.tok.kind {
	case .Minus:
		op, bp = .Neg, BP_UNARY
	case .Tilde:
		op, bp = .Bit_Not, BP_UNARY
	case .Plus:
		next(p) or_return
		return parse_expr(p, BP_UNARY)
	case .Ident:
		if p.tok.text != "not" do return parse_primary(p)
		if min_bp > BP_NOT do return nil, fail(p, .Syntax, offset, "not must be parenthesized here")
		op, bp = .Not, BP_NOT
	case:
		return parse_primary(p)
	}

	next(p) or_return
	operand := parse_expr(p, bp) or_return
	return new_expr(p, offset, mdata.Unary{op, operand}), true
}

// An atom followed by any number of .member accesses and [index]es.
@(private = "file")
parse_primary :: proc(p: ^Parser) -> (e: ^mdata.Expr, ok: bool) {
	e = parse_atom(p) or_return

	for {
		#partial switch p.tok.kind {
		case .Dot:
			next(p) or_return
			if p.tok.kind != .Ident do return nil, fail(p, .Syntax, p.tok.offset, "expected a name after ., found %s", describe(p.tok))
			name := p.tok
			next(p) or_return
			if name.text == "as" && p.tok.kind == .Lt do return nil, fail(p, .Unsupported, name.offset, "casts are not supported")
			e = new_expr(p, name.offset, mdata.Member{e, strings.clone(name.text, p.allocator)})
		case .L_Paren:
			return nil, fail(p, .Unsupported, p.tok.offset, "method calls are not supported")
		case .L_Bracket:
			offset := p.tok.offset
			next(p) or_return
			index := parse_expr(p, 0) or_return
			if p.tok.kind != .R_Bracket do return nil, fail(p, .Syntax, p.tok.offset, "expected ], found %s", describe(p.tok))
			next(p) or_return
			e = new_expr(p, offset, mdata.Index{e, index})
		case:
			return e, true
		}
	}
}

@(private = "file")
KEYWORDS :: [?]string{"and", "or", "not"}

@(private = "file")
parse_atom :: proc(p: ^Parser) -> (e: ^mdata.Expr, ok: bool) {
	t := p.tok

	#partial switch t.kind {
	case .Int:
		next(p) or_return
		return new_expr(p, t.offset, mdata.Int_Literal{t.value}), true
	case .String:
		next(p) or_return
		return new_expr(p, t.offset, mdata.String_Literal{t.str}), true
	case .L_Paren:
		next(p) or_return
		e = parse_expr(p, 0) or_return
		if p.tok.kind != .R_Paren do return nil, fail(p, .Syntax, p.tok.offset, "expected ), found %s", describe(p.tok))
		next(p) or_return
		return e, true
	case .L_Bracket:
		return nil, fail(p, .Unsupported, t.offset, "array literals are not supported")
	case .Ident:
		for k in KEYWORDS {
			if t.text == k do return nil, fail(p, .Syntax, t.offset, "unexpected %s", t.text)
		}
		next(p) or_return
		switch t.text {
		case "true":
			return new_expr(p, t.offset, mdata.Bool_Literal{true}), true
		case "false":
			return new_expr(p, t.offset, mdata.Bool_Literal{false}), true
		case "sizeof", "bitsizeof":
			// as in Kaitai, sizeof< is always one, whatever fields there are
			if p.tok.kind == .Lt do return parse_size_of(p, t)
		}
		if p.tok.kind != .Colon_Colon do return new_expr(p, t.offset, mdata.Name{strings.clone(t.text, p.allocator)}), true

		next(p) or_return
		if p.tok.kind != .Ident do return nil, fail(p, .Syntax, p.tok.offset, "expected an enum value after ::, found %s", describe(p.tok))
		value := p.tok
		next(p) or_return
		if p.tok.kind == .Colon_Colon do return nil, fail(p, .Unsupported, t.offset, "enums of other types (a::b::c) are not supported")
		return new_expr(p, t.offset, mdata.Enum_Constant{strings.clone(t.text, p.allocator), strings.clone(value.text, p.allocator)}), true
	}

	return nil, fail(p, .Syntax, t.offset, "unexpected %s", describe(t))
}

// The rest of sizeof<t> or bitsizeof<t>, after keyword: <, a type name,
// which can be a path (a::b), and >.
@(private = "file")
parse_size_of :: proc(p: ^Parser, keyword: Token) -> (e: ^mdata.Expr, ok: bool) {
	next(p) or_return
	b := strings.builder_make(p.allocator)
	for {
		if p.tok.kind != .Ident do return nil, fail(p, .Syntax, p.tok.offset, "expected a type name in %s<>, found %s", keyword.text, describe(p.tok))
		strings.write_string(&b, p.tok.text)
		next(p) or_return
		if p.tok.kind != .Colon_Colon do break
		strings.write_string(&b, "::")
		next(p) or_return
	}
	if p.tok.kind != .Gt do return nil, fail(p, .Syntax, p.tok.offset, "expected > after the type name, found %s", describe(p.tok))
	next(p) or_return
	return new_expr(p, keyword.offset, mdata.Size_Of{strings.to_string(b), keyword.text == "bitsizeof"}), true
}
