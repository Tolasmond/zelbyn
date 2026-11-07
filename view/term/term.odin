#+build linux, darwin, freebsd, openbsd, netbsd
// Package term is the viewer's terminal, on POSIX: it takes it, in raw mode,
// on the alternate screen, with the cursor hidden and the mouse reported;
// gives it back, also when the viewer is ended by a signal or a failed
// assertion; tells its size; waits for its input, or a resize, and decodes
// it (view/vt); and writes a grid to it (view/grid). It is the only package
// of the viewer that touches the terminal (doc/arch.md §15.3).
package term

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:strings"
import "core:sys/posix"
import "../grid"
import "../vt"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

// ioctl, which POSIX leaves out, for the terminal's size
@(private)
foreign libc {
	ioctl :: proc(fd: posix.FD, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

when ODIN_OS == .Linux {
	@(private)
	TIOCGWINSZ :: 0x5413
} else {
	@(private)
	TIOCGWINSZ :: 0x40087468
}

// not in POSIX, nor in posix.Signal
@(private)
SIGWINCH :: posix.Signal(posix.SIGWINCH)

@(private)
Winsize :: struct {
	row, col, xpixel, ypixel: c.ushort,
}

// How long, in milliseconds, a read that ends in ESC, or in a sequence not
// finished, waits for the rest, before it is taken as it is (vt.flush).
ESCAPE_WAIT :: 25

Error :: enum {
	None,
	Not_A_Terminal, // stdin or stdout is not a terminal
	Attributes,     // its termios could not be read or set
	Pipe,           // the pipe a resize is told by could not be made
	Signals,        // a signal's handler could not be set
	Read,
	Write,
	Closed,         // stdin ended
}

// A terminal taken by open. A process takes one at a time.
Terminal :: struct {
	decoder: vt.Decoder,
	pending: bool,      // the last read ended in ESC, or in a sequence not finished
	shown:   grid.Grid, // what the terminal shows, after draw
	drawn:   bool,      // shown is on screen; until then, draw writes every cell
	out:     strings.Builder,
}

// What it is taken into, and given back from, in this order: the alternate
// screen, the cursor hidden, and the mouse reported, its buttons, its moves
// while one is held, and in SGR's encoding (1000, 1002, 1006).
@(private)
TAKE :: "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h"
@(private)
GIVE_BACK :: "\x1b[0m\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[?1049l"

// The signals that end the process, after which the terminal is given back
// before their default action: those sent to end it, and those of a fault.
@(private)
ENDING := [?]posix.Signal{.SIGTERM, .SIGHUP, .SIGINT, .SIGQUIT, .SIGSEGV, .SIGBUS, .SIGFPE, .SIGILL, .SIGABRT, .SIGTRAP}

// What a signal's handler needs, which it gets from nowhere else.
@(private)
taken: bool // set, it is given back once; read and set atomically
@(private)
saved: posix.termios // the terminal's attributes before open
@(private)
wake := [2]posix.FD{-1, -1} // a pipe that a resize writes a byte to
@(private)
before: [len(ENDING) + 1]posix.sigaction_t // the handlers before open, of ENDING then SIGWINCH

// Takes the terminal on stdin and stdout. When it cannot, it is as it was,
// with an error. Given back by close.
open :: proc(t: ^Terminal) -> Error {
	if !posix.isatty(0) || !posix.isatty(1) do return .Not_A_Terminal
	if posix.tcgetattr(0, &saved) != .OK do return .Attributes
	if posix.pipe(&wake) != .OK {
		wake = {-1, -1}
		return .Pipe
	}
	for fd in wake {
		// a handler never blocks on a full pipe, and a resize already told is enough
		posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | transmute(c.int)posix.O_Flags{.NONBLOCK})
		posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	}
	if !set_handlers() {
		close_pipe()
		return .Signals
	}

	raw := saved
	// as cfmakeraw, which POSIX leaves out: bytes as they are typed, not
	// echoed, with no signal for Ctrl+C, and output as it is written
	raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag -= posix.CSIZE + {.PARENB}
	raw.c_cflag += {.CS8}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(0, .TCSAFLUSH, &raw) != .OK {
		unset_handlers()
		close_pipe()
		return .Attributes
	}
	intrinsics.atomic_store(&taken, true)
	t^ = {}
	if !write_all(1, TAKE) {
		close(t)
		return .Write
	}
	return .None
}

// Gives the terminal back as it was before open, and frees t.
close :: proc(t: ^Terminal) {
	give_back()
	unset_handlers()
	close_pipe()
	grid.destroy(&t.shown)
	strings.builder_destroy(&t.out)
	t^ = {}
}

// The terminal's columns and lines; 80 × 24 when it does not tell.
size :: proc() -> (width, height: int) {
	ws: Winsize
	if ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.col > 0 && ws.row > 0 do return int(ws.col), int(ws.row)
	return 80, 24
}

// Waits for input, or a resize, and appends their events to events: those
// of a read, and a Resize when the terminal was resized; at least one. A
// read that ends in ESC, or in a sequence not finished, waits ESCAPE_WAIT
// for the rest, then takes it as it is.
wait :: proc(t: ^Terminal, events: ^[dynamic]vt.Event) -> Error {
	buf: [4096]u8
	for start := len(events); len(events) == start; {
		fds := [2]posix.pollfd{{fd = 0, events = {.IN}}, {fd = wake[0], events = {.IN}}}
		n := posix.poll(&fds[0], len(fds), t.pending ? ESCAPE_WAIT : -1)
		if n < 0 {
			if posix.errno() == .EINTR do continue
			return .Read
		}
		if n == 0 {
			// no more came: what the last read left is taken as it is
			vt.flush(&t.decoder, events)
			t.pending = false
			continue
		}
		if fds[1].revents & {.IN} != {} {
			for posix.read(wake[0], &buf[0], len(buf)) > 0 {}
			append(events, vt.Resize{})
		}
		if fds[0].revents & {.IN, .HUP, .ERR} != {} {
			got := posix.read(0, &buf[0], len(buf))
			if got < 0 {
				if e := posix.errno(); e == .EINTR || e == .EAGAIN do continue
				return .Read
			}
			if got == 0 do return .Closed
			t.pending = vt.decode(&t.decoder, buf[:got], events)
		}
	}
	return .None
}

// Writes g to the terminal, in one write: the cells that differ from those
// it shows, or every cell at first and after a resize (grid.render).
draw :: proc(t: ^Terminal, g: ^grid.Grid) -> Error {
	strings.builder_reset(&t.out)
	grid.render(t.drawn ? &t.shown : nil, g, &t.out)
	if !write_all(1, strings.to_string(t.out)) {
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

// Gives the terminal back, once, with only calls safe in a signal's
// handler: the escapes, then the attributes, which drop input not read, as
// mouse reports that would reach the shell.
@(private)
give_back :: proc "contextless" () {
	if !intrinsics.atomic_exchange(&taken, false) do return
	write_all(1, GIVE_BACK)
	posix.tcsetattr(0, .TCSAFLUSH, &saved)
}

@(private)
on_ending :: proc "c" (sig: posix.Signal) {
	give_back()
	// the handler is the default again (RESETHAND): raised, the signal is
	// taken when this returns, as it would have been
	posix.raise(sig)
}

@(private)
on_resize :: proc "c" (sig: posix.Signal) {
	e := posix.errno()
	b := u8(1)
	posix.write(wake[1], &b, 1)
	posix.errno(e)
}

@(private)
set_handlers :: proc() -> bool {
	act := posix.sigaction_t {
		sa_handler = on_ending,
		sa_flags   = {.RESETHAND},
	}
	posix.sigemptyset(&act.sa_mask)
	for sig, i in ENDING {
		if posix.sigaction(sig, &act, &before[i]) != .OK {
			for j in 0 ..< i do posix.sigaction(ENDING[j], &before[j], nil)
			return false
		}
	}
	resize := posix.sigaction_t {
		sa_handler = on_resize,
		sa_flags   = {.RESTART},
	}
	posix.sigemptyset(&resize.sa_mask)
	if posix.sigaction(SIGWINCH, &resize, &before[len(ENDING)]) != .OK {
		for sig, i in ENDING do posix.sigaction(sig, &before[i], nil)
		return false
	}
	return true
}

@(private)
unset_handlers :: proc() {
	for sig, i in ENDING do posix.sigaction(sig, &before[i], nil)
	posix.sigaction(SIGWINCH, &before[len(ENDING)], nil)
}

@(private)
close_pipe :: proc() {
	for &fd in wake {
		if fd >= 0 do posix.close(fd)
		fd = -1
	}
}

// Writes all of s to fd, again after a signal.
@(private)
write_all :: proc "contextless" (fd: posix.FD, s: string) -> bool {
	for rest := s; len(rest) > 0; {
		n := posix.write(fd, raw_data(rest), c.size_t(len(rest)))
		if n < 0 {
			if posix.errno() == .EINTR do continue
			return false
		}
		rest = rest[n:]
	}
	return true
}
