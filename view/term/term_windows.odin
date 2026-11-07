#+build windows
// Package term is the viewer's terminal, on Windows: it takes the console,
// with its virtual terminal's input and output, on the alternate screen,
// with the cursor hidden and the mouse reported; gives it back, also when
// the viewer is ended by Ctrl+Break, the console's closing, a fault or a
// failed assertion; tells its size; waits for its input, or a resize, and
// decodes it (view/vt); and writes a grid to it (view/grid). It is the only
// package of the viewer that touches the terminal (doc/arch.md §15.3).
package term

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import win "core:sys/windows"
import "../grid"
import "../vt"

// How long, in milliseconds, a read that ends in ESC, or in a sequence not
// finished, waits for the rest, before it is taken as it is (vt.flush).
ESCAPE_WAIT :: 25

Error :: enum {
	None,
	Not_A_Terminal, // stdin or stdout is not a console
	Attributes,     // its modes or its code page could not be read or set
	Signals,        // the handler of its control events could not be set
	Read,
	Write,
	Out_Of_Memory,  // what a draw writes could not be made
}

// A terminal taken by open. A process takes one at a time.
Terminal :: struct {
	decoder:   vt.Decoder,
	pending:   bool,      // the last read ended in ESC, or in a sequence not finished
	read_at:   time.Tick, // when that read was, which ESCAPE_WAIT counts from
	surrogate: u16,       // a high surrogate that the last read ended in, or 0
	shown:     grid.Grid, // what the terminal shows, after draw
	drawn:     bool,      // shown is on screen; until then, draw writes every cell
	out:       strings.Builder,
}

// What it is taken into, and given back from, in this order: the alternate
// screen, the cursor hidden, and the mouse reported, its buttons, its moves
// while one is held, and in SGR's encoding (1000, 1002, 1006).
@(private)
TAKE :: "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h"
@(private)
GIVE_BACK :: "\x1b[0m\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[?1049l"

// not in core:sys/windows: needed to turn off Quick Edit, which would take
// the mouse
@(private)
ENABLE_EXTENDED_FLAGS :: win.DWORD(0x0080)

// The input's mode while taken: what is typed as the virtual terminal's
// bytes, not echoed, with no line editing and no signal for Ctrl+C, and a
// resize as an event; with no mouse events of the console's own, nor Quick
// Edit, so that the mouse is reported in the terminal's escapes.
@(private)
INPUT_MODE :: win.ENABLE_VIRTUAL_TERMINAL_INPUT | win.ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS
// The output's: escapes taken as the virtual terminal's, and a line feed
// that only moves down
@(private)
OUTPUT_MODE :: win.ENABLE_PROCESSED_OUTPUT | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.DISABLE_NEWLINE_AUTO_RETURN

// What the handlers need, which they get from nowhere else.
@(private)
taken: bool // set, it is given back once; read and set atomically
@(private)
input, output: win.HANDLE
@(private)
saved_input, saved_output: win.DWORD // the console's modes before open
@(private)
saved_cp: win.CODEPAGE // its output's code page before open
@(private)
filter_before: win.LPTOP_LEVEL_EXCEPTION_FILTER // the fault's filter before open

// Takes the console on stdin and stdout. When it cannot, it is as it was,
// with an error. Given back by close.
open :: proc(t: ^Terminal) -> Error {
	input = win.GetStdHandle(win.STD_INPUT_HANDLE)
	output = win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if !win.GetConsoleMode(input, &saved_input) || !win.GetConsoleMode(output, &saved_output) do return .Not_A_Terminal
	saved_cp = win.GetConsoleOutputCP()
	if saved_cp == win.CODEPAGE(0) do return .Attributes
	if !win.SetConsoleCtrlHandler(on_control, win.TRUE) do return .Signals
	filter_before = win.SetUnhandledExceptionFilter(on_fault)

	// taken before the console is changed: a handler that runs now sets
	// again what is not changed yet, which is harmless
	intrinsics.atomic_store(&taken, true)
	// what is written is UTF-8, as grid.render makes it; what is read is
	// UTF-16, whatever the input's code page
	if !win.SetConsoleOutputCP(.UTF8) ||
	   !win.SetConsoleMode(output, OUTPUT_MODE) ||
	   !win.SetConsoleMode(input, INPUT_MODE) {
		give_back()
		unset_handlers()
		return .Attributes
	}
	t^ = {}
	if !write_all(TAKE) {
		close(t)
		return .Write
	}
	return .None
}

// Gives the console back as it was before open, and frees t.
close :: proc(t: ^Terminal) {
	give_back()
	unset_handlers()
	grid.destroy(&t.shown)
	strings.builder_destroy(&t.out)
	t^ = {}
}

// The terminal's columns and lines, of the console's window; 80 × 24 when
// it does not tell.
size :: proc() -> (width, height: int) {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	out := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if win.GetConsoleScreenBufferInfo(out, &info) {
		w := int(info.srWindow.Right) - int(info.srWindow.Left) + 1
		h := int(info.srWindow.Bottom) - int(info.srWindow.Top) + 1
		if w > 0 && h > 0 do return w, h
	}
	return 80, 24
}

// Waits for input, or a resize, and appends their events to events: those
// of a read, and a Resize when the console was resized; at least one. A
// read that ends in ESC, or in a sequence not finished, waits ESCAPE_WAIT
// from that read for the rest, also across calls that a resize ends, then
// takes it as it is.
wait :: proc(t: ^Terminal, events: ^[dynamic]vt.Event) -> Error {
	records: [512]win.INPUT_RECORD
	// what the records' characters are in UTF-8, decoded when it is full,
	// as a key held is one record with its count of repeats
	buf: [4096]u8
	for start := len(events); len(events) == start; {
		timeout := win.INFINITE
		if t.pending {
			left := ESCAPE_WAIT * time.Millisecond - time.tick_since(t.read_at)
			timeout = left <= 0 ? 0 : win.DWORD((left + time.Millisecond - 1) / time.Millisecond)
		}
		switch win.WaitForSingleObject(input, timeout) {
		case win.WAIT_OBJECT_0:
		case win.WAIT_TIMEOUT:
			// no more came: what the last read left is taken as it is
			vt.flush(&t.decoder, events)
			t.pending = false
			continue
		case:
			return .Read
		}
		waiting: win.DWORD
		if !win.GetNumberOfConsoleInputEvents(input, &waiting) do return .Read
		if waiting == 0 do continue
		got: win.DWORD
		if !win.ReadConsoleInputW(input, &records[0], min(waiting, len(records)), &got) do return .Read

		n := 0
		resized := false
		for r in records[:got] {
			#partial switch r.EventType {
			case .KEY_EVENT:
				// the virtual terminal's input is the characters of key
				// presses; a release repeats the press's
				key := r.Event.KeyEvent
				if !key.bKeyDown || key.uChar.UnicodeChar == 0 do continue
				for _ in 0 ..< max(key.wRepeatCount, 1) {
					// a unit is at most 4 bytes, with the high surrogate before it
					if n > len(buf) - 4 {
						vt.decode(&t.decoder, buf[:n], events)
						n = 0
					}
					n += append_utf16(t, buf[n:], u16(key.uChar.UnicodeChar))
				}
			case .WINDOW_BUFFER_SIZE_EVENT:
				resized = true
			}
		}
		if n > 0 {
			t.pending = vt.decode(&t.decoder, buf[:n], events)
			t.read_at = time.tick_now()
		}
		if resized do append(events, vt.Resize{})
	}
	return .None
}

// Appends the UTF-8 of u, a unit of UTF-16, to buf, with the high surrogate
// before it; returns the bytes appended. A surrogate not paired is U+FFFD.
@(private)
append_utf16 :: proc(t: ^Terminal, buf: []u8, u: u16) -> (n: int) {
	put :: proc(buf: []u8, r: rune) -> int {
		b, w := utf8.encode_rune(r)
		copy(buf, b[:w])
		return w
	}
	if t.surrogate != 0 {
		high := t.surrogate
		t.surrogate = 0
		if u >= 0xdc00 && u < 0xe000 do return put(buf, 0x10000 + (rune(high) - 0xd800) << 10 + (rune(u) - 0xdc00))
		n = put(buf, utf8.RUNE_ERROR)
	}
	switch {
	case u >= 0xd800 && u < 0xdc00:
		t.surrogate = u
	case u >= 0xdc00 && u < 0xe000:
		n += put(buf[n:], utf8.RUNE_ERROR)
	case:
		n += put(buf[n:], rune(u))
	}
	return
}

// Writes g to the terminal, in one write: the cells that differ from those
// it shows, or every cell at first and after a resize (grid.render). When
// it cannot, the next draw writes every cell.
draw :: proc(t: ^Terminal, g: ^grid.Grid) -> Error {
	strings.builder_reset(&t.out)
	if grid.render(t.drawn ? &t.shown : nil, g, &t.out) != nil {
		t.drawn = false
		return .Out_Of_Memory
	}
	if !write_all(strings.to_string(t.out)) {
		t.drawn = false
		return .Write
	}
	// when the copy cannot be made, the next draw writes every cell
	t.drawn = grid.copy_from(&t.shown, g) == nil
	return .None
}

// For context.assertion_failure_proc while the terminal is taken: gives it
// back, so that the message is seen, then fails as Odin does.
assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	give_back()
	runtime.default_assertion_failure_proc(prefix, message, loc)
}

// Gives the console back, once: the escapes, then its modes and code page,
// then drops input not read, as mouse reports that would reach the shell.
@(private)
give_back :: proc "contextless" () {
	if !intrinsics.atomic_exchange(&taken, false) do return
	write_all(GIVE_BACK)
	win.SetConsoleMode(output, saved_output)
	win.SetConsoleMode(input, saved_input)
	win.SetConsoleOutputCP(saved_cp)
	win.FlushConsoleInputBuffer(input)
}

// Ctrl+Break, and the console's closing, the user's logging off and the
// system's shutting down, which end the process: the console is given
// back, then the next handler, at last the default one, ends it. Ctrl+C is
// input while the console is taken, and comes here only when it is not.
@(private)
on_control :: proc "system" (kind: win.DWORD) -> win.BOOL {
	give_back()
	return win.FALSE
}

// A fault that nothing handles: the console is given back, then the filter
// before open, if any, decides what is done.
@(private)
on_fault :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	give_back()
	if filter_before != nil do return filter_before(info)
	return win.EXCEPTION_CONTINUE_SEARCH
}

@(private)
unset_handlers :: proc() {
	win.SetUnhandledExceptionFilter(filter_before)
	win.SetConsoleCtrlHandler(on_control, win.FALSE)
	filter_before = nil
}

// Writes all of s to stdout.
@(private)
write_all :: proc "contextless" (s: string) -> bool {
	for rest := s; len(rest) > 0; {
		written: win.DWORD
		chunk := win.DWORD(min(len(rest), 1 << 30))
		if !win.WriteFile(output, raw_data(rest), chunk, &written, nil) || written == 0 do return false
		rest = rest[written:]
	}
	return true
}
