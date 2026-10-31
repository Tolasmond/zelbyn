// zelbyn-view: a viewer of a file decoded with a schema, in the terminal.
// It runs on Linux only, as hnoss, the library it draws with (a submodule
// in view/hnoss), does. It takes its command line as zelbyn does
// (view/session), and shows the decoded tree as an outline beside the
// file's bytes (view/screen), also after a failed decode, with its error.
package main

import "core:fmt"
import "core:os"
import "hnoss"
import "screen"
import "session"

main :: proc() {
	os.exit(run(os.args)) // os.exit skips defers: run has already cleaned up
}

// Runs the command line args (args[0] the program's name): makes the
// session and shows it until the user quits. A usage error, or a schema or
// file that cannot be read, is reported on stderr as zelbyn reports it,
// before the terminal is taken. Returns the exit code: 0 on success and
// after --help, 1 on an error, and 2 on a usage error.
run :: proc(args: []string) -> int {
	s: session.Session
	defer session.destroy(&s)
	if code, ok := session.make_session(&s, args, os.to_stream(os.stdout), os.to_stream(os.stderr)); !ok do return code

	// show has given the terminal back by now, so the message is seen
	if err := show(&s); err != .None {
		fmt.eprintfln("error: terminal: %v", err)
		return 1
	}
	return 0
}

// Takes the terminal and shows s until q, Esc or Ctrl+C, then gives the
// terminal back.
show :: proc(s: ^session.Session) -> hnoss.Error {
	context.assertion_failure_proc = hnoss.assertion_failure_proc
	term := hnoss.init(hnoss.DEFAULT_OPTIONS + {.Mouse_Capture}) or_return
	defer hnoss.deinit(&term)

	app: screen.App
	screen.init(&app, s)
	defer screen.destroy(&app)
	events: []hnoss.Event
	loop: for {
		f := hnoss.begin_frame(&term)
		ui := hnoss.ui(f, events)
		screen.draw(ui, f.area, &app)
		for ev in hnoss.unhandled(ui) {
			if hnoss.is_char(ev, 'q') || hnoss.is_key(ev, .Esc) || hnoss.is_char(ev, 'c', {.Ctrl}) do break loop
		}
		hnoss.end_frame(&term) or_return
		free_all(context.temp_allocator)
		events = hnoss.poll_events(&term, -1)
		if term.error != .None do return term.error
	}
	return .None
}
