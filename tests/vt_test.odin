package tests

import "../view/vt"
import "core:fmt"
import "core:testing"

@(private = "file")
Vt_Case :: struct {
	bytes:   string,
	events:  []vt.Event,
	pending: bool, // the bytes end in ESC, or in a sequence or a character not finished
}

@(private = "file")
key :: proc(code: vt.Key_Code, mods: vt.Modifiers = {}) -> vt.Event {
	return vt.Key{code = code, mods = mods}
}

@(private = "file")
char :: proc(c: rune, mods: vt.Modifiers = {}) -> vt.Event {
	return vt.Key{code = .Char, char = c, mods = mods}
}

@(private = "file")
VT_CASES := []Vt_Case {
	// printable characters, of one to four bytes
	{"a", {vt.Key{code = .Char, char = 'a'}}, false},
	{"Z~ ", {vt.Key{code = .Char, char = 'Z'}, vt.Key{code = .Char, char = '~'}, vt.Key{code = .Char, char = ' '}}, false},
	{"\xc3\xa9", {vt.Key{code = .Char, char = 0xE9}}, false},
	{"\xe6\x97\xa5", {vt.Key{code = .Char, char = 0x65E5}}, false},
	{"\xf0\x9f\x98\x80", {vt.Key{code = .Char, char = 0x1F600}}, false},

	// keys of a byte of their own, and Ctrl with a letter
	{"\r\n\t", {vt.Key{code = .Enter}, vt.Key{code = .Enter}, vt.Key{code = .Tab}}, false},
	{"\x7f\x08", {vt.Key{code = .Backspace}, vt.Key{code = .Backspace}}, false},
	{"\x01\x03\x1a", {vt.Key{code = .Char, char = 'a', mods = {.Ctrl}}, vt.Key{code = .Char, char = 'c', mods = {.Ctrl}}, vt.Key{code = .Char, char = 'z', mods = {.Ctrl}}}, false},
	{"\x00\x1c\x1d\x1f", {vt.Key{code = .Char, char = ' ', mods = {.Ctrl}}, vt.Key{code = .Char, char = '\\', mods = {.Ctrl}}, vt.Key{code = .Char, char = ']', mods = {.Ctrl}}, vt.Key{code = .Char, char = '_', mods = {.Ctrl}}}, false},

	// a lone ESC, pending until flush makes it Esc; Alt as ESC before a key
	{"\x1b", {vt.Key{code = .Esc}}, true},
	{"\x1ba\x1bA", {vt.Key{code = .Char, char = 'a', mods = {.Alt}}, vt.Key{code = .Char, char = 'A', mods = {.Alt}}}, false},
	{"\x1b\x03\x1b\r\x1b\x7f", {vt.Key{code = .Char, char = 'c', mods = {.Alt, .Ctrl}}, vt.Key{code = .Enter, mods = {.Alt}}, vt.Key{code = .Backspace, mods = {.Alt}}}, false},
	{"\x1b\xc3\xa9", {vt.Key{code = .Char, char = 0xE9, mods = {.Alt}}}, false},
	{"\x1b\x1b", {vt.Key{code = .Esc, mods = {.Alt}}}, false},
	{"\x1b\x1b\x1b", {vt.Key{code = .Esc, mods = {.Alt}}, vt.Key{code = .Esc}}, true},
	// ESC [ and ESC O that nothing follows: Alt with [ and O
	{"\x1b[", {vt.Key{code = .Char, char = '[', mods = {.Alt}}}, true},
	{"\x1bO", {vt.Key{code = .Char, char = 'O', mods = {.Alt}}}, true},
	// ESC with a string's first byte that nothing follows: Alt with it, and
	// with ESC after it, Esc too, or the sequence that ESC starts
	{"\x1b]", {vt.Key{code = .Char, char = ']', mods = {.Alt}}}, true},
	{"\x1bP", {vt.Key{code = .Char, char = 'P', mods = {.Alt}}}, true},
	{"\x1bX", {vt.Key{code = .Char, char = 'X', mods = {.Alt}}}, true},
	{"\x1b^", {vt.Key{code = .Char, char = '^', mods = {.Alt}}}, true},
	{"\x1b_", {vt.Key{code = .Char, char = '_', mods = {.Alt}}}, true},
	{"\x1b]\x1b", {vt.Key{code = .Char, char = ']', mods = {.Alt}}, vt.Key{code = .Esc}}, true},
	{"\x1b_\x1b[A", {vt.Key{code = .Char, char = '_', mods = {.Alt}}, vt.Key{code = .Up}}, false},
	// a string with nothing in it, ended by ST or BEL, dropped
	{"\x1b]\x1b\\a\x1bP\x07b", {vt.Key{code = .Char, char = 'a'}, vt.Key{code = .Char, char = 'b'}}, false},

	// the cursor keys, Home and End, in CSI and SS3
	{"\x1b[A\x1b[B\x1b[C\x1b[D", {vt.Key{code = .Up}, vt.Key{code = .Down}, vt.Key{code = .Right}, vt.Key{code = .Left}}, false},
	{"\x1b[H\x1b[F", {vt.Key{code = .Home}, vt.Key{code = .End}}, false},
	{"\x1bOA\x1bOB\x1bOC\x1bOD\x1bOH\x1bOF", {vt.Key{code = .Up}, vt.Key{code = .Down}, vt.Key{code = .Right}, vt.Key{code = .Left}, vt.Key{code = .Home}, vt.Key{code = .End}}, false},
	{"\x1bOM", {vt.Key{code = .Enter}}, false},
	// with xterm's modifiers, 1 + Shift 1, Alt 2, Ctrl 4
	{"\x1b[1;2A\x1b[1;3B\x1b[1;5C\x1b[1;8D", {vt.Key{code = .Up, mods = {.Shift}}, vt.Key{code = .Down, mods = {.Alt}}, vt.Key{code = .Right, mods = {.Ctrl}}, vt.Key{code = .Left, mods = {.Shift, .Alt, .Ctrl}}}, false},
	{"\x1b[1;5H\x1b[1;2F\x1b[1;1A", {vt.Key{code = .Home, mods = {.Ctrl}}, vt.Key{code = .End, mods = {.Shift}}, vt.Key{code = .Up}}, false},
	{"\x1b[Z", {vt.Key{code = .Tab, mods = {.Shift}}}, false},

	// the keys of CSI n ~
	{"\x1b[1~\x1b[7~\x1b[4~\x1b[8~", {vt.Key{code = .Home}, vt.Key{code = .Home}, vt.Key{code = .End}, vt.Key{code = .End}}, false},
	{"\x1b[2~\x1b[3~\x1b[5~\x1b[6~", {vt.Key{code = .Insert}, vt.Key{code = .Delete}, vt.Key{code = .Page_Up}, vt.Key{code = .Page_Down}}, false},
	{"\x1b[3;5~\x1b[5;2~\x1b[6;3~", {vt.Key{code = .Delete, mods = {.Ctrl}}, vt.Key{code = .Page_Up, mods = {.Shift}}, vt.Key{code = .Page_Down, mods = {.Alt}}}, false},

	// F1 to F12: SS3 P to S, CSI 1;m P to S, and CSI n ~
	{"\x1bOP\x1bOQ\x1bOR\x1bOS", {vt.Key{code = .F1}, vt.Key{code = .F2}, vt.Key{code = .F3}, vt.Key{code = .F4}}, false},
	{"\x1b[1;2P\x1b[1;5S", {vt.Key{code = .F1, mods = {.Shift}}, vt.Key{code = .F4, mods = {.Ctrl}}}, false},
	{"\x1b[11~\x1b[12~\x1b[13~\x1b[14~\x1b[15~", {vt.Key{code = .F1}, vt.Key{code = .F2}, vt.Key{code = .F3}, vt.Key{code = .F4}, vt.Key{code = .F5}}, false},
	{"\x1b[17~\x1b[18~\x1b[19~\x1b[20~\x1b[21~\x1b[23~\x1b[24~", {vt.Key{code = .F6}, vt.Key{code = .F7}, vt.Key{code = .F8}, vt.Key{code = .F9}, vt.Key{code = .F10}, vt.Key{code = .F11}, vt.Key{code = .F12}}, false},
	{"\x1b[24;5~", {vt.Key{code = .F12, mods = {.Ctrl}}}, false},

	// SGR's mouse reports: buttons, a release, a drag, the wheel, modifiers,
	// and columns and lines from 0
	{"\x1b[<0;1;1M\x1b[<0;10;5m", {vt.Mouse{kind = .Press, button = .Left, x = 0, y = 0}, vt.Mouse{kind = .Release, button = .Left, x = 9, y = 4}}, false},
	{"\x1b[<1;3;4M\x1b[<2;3;4M", {vt.Mouse{kind = .Press, button = .Middle, x = 2, y = 3}, vt.Mouse{kind = .Press, button = .Right, x = 2, y = 3}}, false},
	{"\x1b[<32;5;6M\x1b[<34;5;6M", {vt.Mouse{kind = .Drag, button = .Left, x = 4, y = 5}, vt.Mouse{kind = .Drag, button = .Right, x = 4, y = 5}}, false},
	{"\x1b[<64;7;8M\x1b[<65;7;8M", {vt.Mouse{kind = .Wheel_Up, x = 6, y = 7}, vt.Mouse{kind = .Wheel_Down, x = 6, y = 7}}, false},
	{"\x1b[<4;1;1M\x1b[<8;1;1M\x1b[<16;1;1M\x1b[<81;2;2M", {vt.Mouse{kind = .Press, button = .Left, mods = {.Shift}}, vt.Mouse{kind = .Press, button = .Left, mods = {.Alt}}, vt.Mouse{kind = .Press, button = .Left, mods = {.Ctrl}}, vt.Mouse{kind = .Wheel_Down, x = 1, y = 1, mods = {.Ctrl}}}, false},
	{"\x1b[<0;300;200M", {vt.Mouse{kind = .Press, button = .Left, x = 299, y = 199}}, false},
	// those not kept: a move with no button, the wheel's left and right, a
	// wheel's release, buttons past the wheel's, and reports out of shape
	{"\x1b[<35;5;6M\x1b[<66;1;1M\x1b[<67;1;1M\x1b[<64;1;1m\x1b[<128;1;1M", {}, false},
	{"\x1b[<0;0;1M\x1b[<0;1;0M\x1b[<0;1M\x1b[<0;1;1;1M\x1b[<0;1;1X\x1b[<0:1;1;1M", {}, false},

	// sequences that are not keys, dropped whole, and the keys around them
	{"\x1b[200~hi\x1b[201~", {vt.Key{code = .Char, char = 'h'}, vt.Key{code = .Char, char = 'i'}}, false},
	{"\x1b[I\x1b[O\x1b[?1;2c\x1b[12;40R\x1b[97;5u\x1b[1:2A\x1b[2A\x1b[99~x", {vt.Key{code = .Char, char = 'x'}}, false},
	{"\x1b[9999999~\x1b[0000005~\x1b[1;2;3;4A\x1b[1;2;3A\x1b[3;5;9~\x1b[;5Ay", {vt.Key{code = .Up, mods = {.Ctrl}}, vt.Key{code = .Char, char = 'y'}}, false},
	// modifiers past Shift, Alt and Ctrl, and so a report of the cursor's
	// position in a column past 8
	{"\x1b[1;9A\x1b[3;17~\x1b[1;40R\x1b[1;0Bx", {vt.Key{code = .Down}, vt.Key{code = .Char, char = 'x'}}, false},
	{"\x1b[11111111111111111111111111111111111111111Ax", {vt.Key{code = .Char, char = 'x'}}, false},
	{"\x1b]0;title\x07a\x1b]0;title\x1b\\b\x1bP+q\x1b\\c\x1b_x\x07d\x1b^x\x07e\x1bXx\x07f", {vt.Key{code = .Char, char = 'a'}, vt.Key{code = .Char, char = 'b'}, vt.Key{code = .Char, char = 'c'}, vt.Key{code = .Char, char = 'd'}, vt.Key{code = .Char, char = 'e'}, vt.Key{code = .Char, char = 'f'}}, false},
	// a string ended by ESC before anything but \: that ESC starts a sequence
	{"\x1b]0;t\x1b[A", {vt.Key{code = .Up}}, false},
	// an SS3 with a final byte of no key
	{"\x1bOxa", {vt.Key{code = .Char, char = 'a'}}, false},
	// an SS3 cut short by another sequence, by a control or by a character,
	// which is read anew
	{"\x1bO\x1b[A", {vt.Key{code = .Up}}, false},
	{"\x1bO\x03a", {vt.Key{code = .Char, char = 'c', mods = {.Ctrl}}, vt.Key{code = .Char, char = 'a'}}, false},
	{"\x1bO\xc3\xa9x", {vt.Key{code = .Char, char = 0xE9}, vt.Key{code = .Char, char = 'x'}}, false},
	// a sequence cut short by another, and by a control, which is read anew
	{"\x1b[1\x1b[A", {vt.Key{code = .Up}}, false},
	{"\x1b[1\x03a", {vt.Key{code = .Char, char = 'c', mods = {.Ctrl}}, vt.Key{code = .Char, char = 'a'}}, false},
	{"\x1b[1\xc3\xa9", {vt.Key{code = .Char, char = 0xE9}}, false},
	// an unfinished one: dropped by flush
	{"\x1b[1;5", {}, true},
	{"\x1b]0;title", {}, true},
	{"\x1b]0;title\x1b", {}, true},

	// bytes that are not UTF-8, and a C1 control encoded in it, dropped
	{"\xff\x80\xbfa", {vt.Key{code = .Char, char = 'a'}}, false},
	{"\xc3a", {vt.Key{code = .Char, char = 'a'}}, false},
	{"\xe0\x80\x80\xed\xa0\x80\xc0\xaf\xf8\x88\x80\x80\x80b", {vt.Key{code = .Char, char = 'b'}}, false},
	{"\xc2\x80\xc2\x9bc", {vt.Key{code = .Char, char = 'c'}}, false},
	{"\x1b\xffd", {vt.Key{code = .Char, char = 'd'}}, false},
	{"\xe6\x97", {}, true},

	// many in one read
	{"ab\x1b[A\x1b[<64;1;1Mc\x1b[6~", {vt.Key{code = .Char, char = 'a'}, vt.Key{code = .Char, char = 'b'}, vt.Key{code = .Up}, vt.Mouse{kind = .Wheel_Up}, vt.Key{code = .Char, char = 'c'}, vt.Key{code = .Page_Down}}, false},
}

// The events of reads, and the pending of the last; when it is, flushed.
@(private = "file")
vt_decode :: proc(reads: ..string) -> (events: [dynamic]vt.Event, pending: bool) {
	d: vt.Decoder
	events = make([dynamic]vt.Event, context.temp_allocator)
	for r in reads do pending = vt.decode(&d, transmute([]u8)r, &events)
	if pending do vt.flush(&d, &events)
	return
}

@(private = "file")
events_text :: proc(events: []vt.Event) -> string {
	return fmt.tprint(events)
}

// Each case decoded in one read, in two at every byte, and a byte a read,
// gives its events: a sequence or a character split between reads is
// decoded whole.
@(test)
vt_decode_cases :: proc(t: ^testing.T) {
	for c in VT_CASES {
		events, pending := vt_decode(c.bytes)
		testing.expectf(t, pending == c.pending, "%q: pending %v", c.bytes, pending)
		want := events_text(c.events)
		testing.expectf(t, events_text(events[:]) == want, "%q: %v, not %v", c.bytes, events[:], want)
		for i in 1 ..< len(c.bytes) {
			split, split_pending := vt_decode(c.bytes[:i], c.bytes[i:])
			testing.expectf(t, split_pending == c.pending, "%q split at %d: pending %v", c.bytes, i, split_pending)
			testing.expectf(t, events_text(split[:]) == want, "%q split at %d: %v, not %v", c.bytes, i, split[:], want)
		}
		bytes := make([]string, len(c.bytes), context.temp_allocator)
		for i in 0 ..< len(c.bytes) do bytes[i] = c.bytes[i:][:1]
		one, one_pending := vt_decode(..bytes)
		testing.expectf(t, one_pending == c.pending, "%q a byte a read: pending %v", c.bytes, one_pending)
		testing.expectf(t, events_text(one[:]) == want, "%q a byte a read: %v, not %v", c.bytes, one[:], want)
	}
}

// What decode keeps pending, and what flush makes of it, then nothing.
@(test)
vt_pending :: proc(t: ^testing.T) {
	d: vt.Decoder
	events := make([dynamic]vt.Event, context.temp_allocator)
	testing.expect(t, !vt.decode(&d, transmute([]u8)string("a"), &events))
	testing.expect(t, vt.decode(&d, transmute([]u8)string("\x1b"), &events))
	// the rest of the sequence, in the next read
	testing.expect(t, !vt.decode(&d, transmute([]u8)string("[B"), &events))
	testing.expect_value(t, events_text(events[:]), events_text({char('a'), key(.Down)}))

	clear(&events)
	testing.expect(t, vt.decode(&d, transmute([]u8)string("\x1b"), &events))
	vt.flush(&d, &events)
	vt.flush(&d, &events)
	testing.expect_value(t, events_text(events[:]), events_text({key(.Esc)}))
	// after flush, ESC then a key is Esc, not Alt
	clear(&events)
	testing.expect(t, !vt.decode(&d, transmute([]u8)string("b"), &events))
	testing.expect_value(t, events_text(events[:]), events_text({char('b')}))

	// after flush ends each case left pending, the decoder starts afresh
	for c in VT_CASES {
		if !c.pending do continue
		clear(&events)
		after: vt.Decoder
		vt.decode(&after, transmute([]u8)c.bytes, &events)
		vt.flush(&after, &events)
		testing.expectf(t, !vt.decode(&after, transmute([]u8)string("x"), &events), "%q, flushed, then x: pending", c.bytes)
		want := make([dynamic]vt.Event, context.temp_allocator)
		append(&want, ..c.events)
		append(&want, char('x'))
		testing.expectf(t, events_text(events[:]) == events_text(want[:]), "%q, flushed, then x: %v", c.bytes, events[:])
	}

	// nothing decodes to a Resize, which the terminal's reader makes
	for c in VT_CASES {
		for e in c.events {
			_, is_resize := e.(vt.Resize)
			testing.expectf(t, !is_resize, "%q", c.bytes)
		}
	}
}
