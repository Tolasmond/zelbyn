// Package vt decodes what a terminal in raw mode sends: the bytes of keys
// and of mouse reports, after ECMA-48's syntax of escape and control
// sequences and xterm's encodings of them, into events. It reads no
// terminal: it is given the bytes of each read, so it is tested on every
// platform (doc/arch.md §15.2).
package vt

import "core:unicode"
import "core:unicode/utf8"

Key_Code :: enum u8 {
	Char, // char, a printable character
	Enter,
	Tab,
	Backspace,
	Esc,
	Up,
	Down,
	Left,
	Right,
	Home,
	End,
	Page_Up,
	Page_Down,
	Insert,
	Delete,
	F1,
	F2,
	F3,
	F4,
	F5,
	F6,
	F7,
	F8,
	F9,
	F10,
	F11,
	F12,
}

Modifier :: enum u8 {
	Shift,
	Alt,
	Ctrl,
}

Modifiers :: bit_set[Modifier; u8]

// A key: one of Key_Code, or with code Char, the character char. Ctrl with
// a letter is the letter, lower case, with Ctrl; a capital is its own
// character, without Shift.
Key :: struct {
	code: Key_Code,
	char: rune,
	mods: Modifiers,
}

Mouse_Kind :: enum u8 {
	Press,
	Release,
	Drag, // a move with a button held
	Wheel_Up,
	Wheel_Down,
}

Button :: enum u8 {
	None, // of a wheel
	Left,
	Middle,
	Right,
}

// A mouse event at column x, line y, from 0 at the top left.
Mouse :: struct {
	kind:   Mouse_Kind,
	button: Button,
	x, y:   int,
	mods:   Modifiers,
}

// The terminal's size changed. The decoder makes none: the terminal's
// reader (view/term) does, when told of it.
Resize :: struct {}

Event :: union {
	Key,
	Mouse,
	Resize,
}

// The bytes of a control sequence's parameters and intermediates kept; a
// longer one is read to its end and dropped.
SEQUENCE_BYTES :: 32

@(private)
State :: enum u8 {
	Ground,
	Utf8,       // in a character of more than one byte
	Escape,     // after ESC
	Csi,        // after ESC [, before the final byte
	Ss3,        // after ESC O
	String,     // in OSC, DCS, SOS, PM or APC, to BEL or ST
	String_Esc, // after ESC in a string, which ST ends
}

// What the decoder keeps from one read to the next: where it is in a
// sequence, or a character, that a read left unfinished.
Decoder :: struct {
	state:    State,
	alt:      bool, // the key being read follows ESC
	seq:      [SEQUENCE_BYTES]u8,
	seq_len:  int,
	too_long: bool,
	char:     [4]u8,
	char_len: int,
	char_end: int, // the bytes of the character being read
}

// Decodes bytes, those of one read, and appends their events to events. A
// sequence or a character that bytes end in is kept in d, and finished by
// the next call's bytes; pending is true then. A lone ESC is pending too:
// the reader waits a little for what may follow it, and calls flush when
// nothing does.
decode :: proc(d: ^Decoder, bytes: []u8, events: ^[dynamic]Event) -> (pending: bool) {
	for b in bytes do step(d, b, events)
	return d.state != .Ground
}

// Ends what d has pending, when no more bytes came for it: a lone ESC is
// the Esc key, ESC [ and ESC O are Alt with [ and O, and the rest of an
// unfinished sequence or character is dropped.
flush :: proc(d: ^Decoder, events: ^[dynamic]Event) {
	#partial switch d.state {
	case .Escape:
		key(d, events, {code = .Esc})
	case .Csi:
		if d.seq_len == 0 && !d.too_long {
			d.alt = true
			key(d, events, {code = .Char, char = '['})
		}
	case .Ss3:
		d.alt = true
		key(d, events, {code = .Char, char = 'O'})
	}
	d^ = {}
}

// Takes byte b.
@(private)
step :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	switch d.state {
	case .Ground:
		ground(d, b, events)
	case .Utf8:
		if b & 0xC0 != 0x80 {
			// not a continuation: the character is dropped, and b read anew
			d.state, d.alt = .Ground, false
			ground(d, b, events)
			return
		}
		d.char[d.char_len] = b
		d.char_len += 1
		if d.char_len < d.char_end do return
		d.state = .Ground
		r, size := utf8.decode_rune(d.char[:d.char_len])
		if (r == utf8.RUNE_ERROR && size == 1) || size != d.char_len || unicode.is_control(r) {
			d.alt = false
			return
		}
		key(d, events, {code = .Char, char = r})
	case .Escape:
		switch b {
		case '[':
			d.state, d.seq_len, d.too_long = .Csi, 0, false
		case 'O':
			d.state = .Ss3
		case ']', 'P', 'X', '^', '_':
			d.state = .String
		case 0x1B:
			// ESC ESC: Alt with Esc
			d.state, d.alt = .Ground, true
			key(d, events, {code = .Esc})
		case:
			// Alt with the key b starts
			d.state, d.alt = .Ground, true
			ground(d, b, events)
		}
	case .Csi:
		switch b {
		case 0x20 ..= 0x3F:
			if d.seq_len < SEQUENCE_BYTES {
				d.seq[d.seq_len] = b
				d.seq_len += 1
			} else {
				d.too_long = true
			}
		case 0x40 ..= 0x7E:
			d.state = .Ground
			if !d.too_long do csi(d, d.seq[:d.seq_len], b, events)
			d.alt = false
		case 0x1B:
			// a sequence cut short by another
			d.state, d.alt = .Escape, false
		case:
			// a control or a byte past ASCII ends it, dropped, and is read
			// anew, so that Ctrl+C typed in the middle of one is not lost
			d.state, d.alt = .Ground, false
			ground(d, b, events)
		}
	case .Ss3:
		d.state = .Ground
		code: Key_Code
		switch b {
		case 'A': code = .Up
		case 'B': code = .Down
		case 'C': code = .Right
		case 'D': code = .Left
		case 'H': code = .Home
		case 'F': code = .End
		case 'P': code = .F1
		case 'Q': code = .F2
		case 'R': code = .F3
		case 'S': code = .F4
		case 'M': code = .Enter // the keypad's
		case:
			d.alt = false
			return
		}
		key(d, events, {code = code})
	case .String:
		switch b {
		case 0x07:
			d.state, d.alt = .Ground, false
		case 0x1B:
			d.state = .String_Esc
		}
	case .String_Esc:
		d.state, d.alt = .Ground, false
		// ST ends the string; ESC before anything else ends it too, and
		// starts a sequence of its own
		if b != '\\' {
			d.state = .Escape
			step(d, b, events)
		}
	}
}

// Takes byte b outside a sequence: a key of its own, ESC, or the first
// byte of a character.
@(private)
ground :: proc(d: ^Decoder, b: u8, events: ^[dynamic]Event) {
	switch b {
	case 0x1B:
		d.state = .Escape
	case '\r', '\n':
		key(d, events, {code = .Enter})
	case '\t':
		key(d, events, {code = .Tab})
	case 0x7F, 0x08:
		key(d, events, {code = .Backspace})
	case 0x00:
		key(d, events, {code = .Char, char = ' ', mods = {.Ctrl}})
	case 0x01 ..= 0x1A:
		key(d, events, {code = .Char, char = rune('a' + b - 1), mods = {.Ctrl}})
	case 0x1C ..= 0x1F:
		key(d, events, {code = .Char, char = rune(b + 0x40), mods = {.Ctrl}})
	case 0x20 ..= 0x7E:
		key(d, events, {code = .Char, char = rune(b)})
	case 0xC2 ..= 0xDF:
		start_char(d, b, 2)
	case 0xE0 ..= 0xEF:
		start_char(d, b, 3)
	case 0xF0 ..= 0xF4:
		start_char(d, b, 4)
	case:
		// a byte that starts no character of UTF-8
		d.alt = false
	}
}

@(private)
start_char :: proc(d: ^Decoder, b: u8, size: int) {
	d.state = .Utf8
	d.char[0] = b
	d.char_len, d.char_end = 1, size
}

// Appends k, with Alt when it followed ESC.
@(private)
key :: proc(d: ^Decoder, events: ^[dynamic]Event, k: Key) {
	k := k
	if d.alt do k.mods += {.Alt}
	d.alt = false
	append(events, k)
}

// Decodes the control sequence ESC [ params final: a key, or a mouse event
// in SGR's encoding; any other is dropped.
@(private)
csi :: proc(d: ^Decoder, params: []u8, final: u8, events: ^[dynamic]Event) {
	if len(params) > 0 && params[0] == '<' {
		if final == 'M' || final == 'm' do mouse(params[1:], final == 'm', events)
		return
	}
	n: [3]int
	count, ok := numbers(params, n[:])
	if !ok do return
	// xterm's modifiers are 1 + their bits: Shift 1, Alt 2, Ctrl 4
	mods: Modifiers
	if count >= 2 {
		bits := max(n[1] - 1, 0)
		if bits & 1 != 0 do mods += {.Shift}
		if bits & 2 != 0 do mods += {.Alt}
		if bits & 4 != 0 do mods += {.Ctrl}
	}
	code: Key_Code
	switch final {
	case 'A': code = .Up
	case 'B': code = .Down
	case 'C': code = .Right
	case 'D': code = .Left
	case 'H': code = .Home
	case 'F': code = .End
	case 'P': code = .F1
	case 'Q': code = .F2
	case 'R': code = .F3
	case 'S': code = .F4
	case 'Z':
		code = .Tab
		mods += {.Shift}
	case '~':
		if count == 0 do return
		switch n[0] {
		case 1, 7:  code = .Home
		case 2:     code = .Insert
		case 3:     code = .Delete
		case 4, 8:  code = .End
		case 5:     code = .Page_Up
		case 6:     code = .Page_Down
		case 11:    code = .F1
		case 12:    code = .F2
		case 13:    code = .F3
		case 14:    code = .F4
		case 15:    code = .F5
		case 17:    code = .F6
		case 18:    code = .F7
		case 19:    code = .F8
		case 20:    code = .F9
		case 21:    code = .F10
		case 23:    code = .F11
		case 24:    code = .F12
		case:
			// bracketed paste's markers, 200 and 201, and others
			return
		}
	case:
		return
	}
	// a key with no parameter of modifiers has a first parameter of 1 at
	// most, as in CSI 1;5A
	if final != '~' && count >= 1 && n[0] > 1 do return
	append(events, Key{code = code, mods = mods})
}

// Decodes SGR's mouse report CSI < b ; x ; y M (a press or a move) or m (a
// release): b's low bits are the button, 0 to 2, or 3 for none, 4 is
// Shift, 8 Alt, 16 Ctrl, 32 a move and 64 the wheel; x and y count from 1.
@(private)
mouse :: proc(params: []u8, release: bool, events: ^[dynamic]Event) {
	n: [3]int
	count, ok := numbers(params, n[:])
	if !ok || count != 3 || n[1] < 1 || n[2] < 1 do return
	b := n[0]
	m := Mouse{x = n[1] - 1, y = n[2] - 1}
	if b & 4 != 0 do m.mods += {.Shift}
	if b & 8 != 0 do m.mods += {.Alt}
	if b & 16 != 0 do m.mods += {.Ctrl}
	low := b & 3
	switch {
	case b >= 128:
		// buttons past the wheel's
		return
	case b & 64 != 0:
		// a wheel's left and right, 2 and 3, are not kept
		if low > 1 || release do return
		m.kind = low == 0 ? .Wheel_Up : .Wheel_Down
	case:
		if low == 3 {
			// a move with no button held, which mode 1003 reports
			return
		}
		m.button = Button(low + 1)
		m.kind = release ? .Release : b & 32 != 0 ? .Drag : .Press
	}
	append(events, m)
}

// The numbers of params, separated by ';', into n: count of them, an empty
// one 0, and ok false when one is not a number of at most 6 digits, or
// there are more than n holds.
@(private)
numbers :: proc(params: []u8, n: []int) -> (count: int, ok: bool) {
	if len(params) == 0 do return 0, true
	digits := 0
	n[0] = 0
	count = 1
	for b in params {
		switch b {
		case '0' ..= '9':
			digits += 1
			if digits > 6 do return
			n[count - 1] = n[count - 1] * 10 + int(b - '0')
		case ';':
			if count == len(n) do return
			n[count] = 0
			count += 1
			digits = 0
		case:
			return
		}
	}
	return count, true
}
