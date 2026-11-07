// zelbyn-view: a viewer of a file decoded with a schema, in the terminal.
// It takes its command line as zelbyn does (view/session), and shows the
// decoded tree as an outline beside the file's bytes (view/screen), also
// after a failed decode, with its error. It draws with a terminal library
// of its own (view/grid, view/vt, view/term), on POSIX and on Windows.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "grid"
import "screen"
import "session"
import "term"
import "vt"

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
	if err := show(&s); err != nil {
		fmt.eprintfln("error: terminal: %v", err)
		return 1
	}
	return 0
}

Show_Error :: union {
	term.Error,
	mem.Allocator_Error,
}

// Takes the terminal and shows s until q, Esc or Ctrl+C, then gives the
// terminal back. The screen is drawn, then each event of a read handled in
// turn, then it is drawn again, once; only the cells that changed are
// written.
show :: proc(s: ^session.Session) -> Show_Error {
	context.assertion_failure_proc = term.assertion_failure_proc
	t: term.Terminal
	if err := term.open(&t); err != .None do return err
	defer term.close(&t)

	app: screen.App
	screen.init(&app, s)
	defer screen.destroy(&app)
	g: grid.Grid
	defer grid.destroy(&g)
	events := make([dynamic]vt.Event)
	defer delete(events)
	width, height := term.size()
	for {
		if err := grid.resize(&g, width, height); err != nil do return err
		screen.draw(&g, &app)
		if err := term.draw(&t, &g); err != .None do return err
		free_all(context.temp_allocator)

		clear(&events)
		if err := term.wait(&t, &events); err != .None do return err
		for e in events {
			// the events after a resize are on a screen of the new size
			if _, resized := e.(vt.Resize); resized do width, height = term.size()
			if screen.handle(&app, e, width, height) == .Quit do return nil
		}
	}
}
