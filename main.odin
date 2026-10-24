package main

import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "zelbyn/cli"

main :: proc() {
	context.logger = log.create_file_logger(os.stderr, lowest = .Warning)

	exit_code := run_tracked(os.args, os.to_stream(os.stdout), os.to_stream(os.stderr))

	os.exit(exit_code) // os.exit skips defers: run_tracked has already cleaned up
}

// Calls cli.execute. In debug builds (-debug) it runs under a tracking
// allocator and reports leaks and bad frees on stderr, either of which turns
// exit code 0 into 1.
run_tracked :: proc(args: []string, stdout, stderr: io.Writer) -> int {
	when ODIN_DEBUG {
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, context.allocator)
		tracking_allocator.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		exit_code := cli.execute(args, stdout, stderr)

		if reset_tracking_allocator(&tracking_allocator) && exit_code == 0 {
			exit_code = 1
		}
		mem.tracking_allocator_destroy(&tracking_allocator)
		return exit_code
	} else {
		return cli.execute(args, stdout, stderr)
	}
}

reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
	leaks := false

	if len(a.allocation_map) != 0 {
		fmt.eprintfln("%v leaks found!", len(a.allocation_map))
	}

	for _, value in a.allocation_map {
		fmt.eprintfln("%v: Leaked %v bytes", value.location, value.size)
		leaks = true
	}

	if len(a.bad_free_array) != 0 {
		fmt.eprintfln("%v bad frees found!", len(a.bad_free_array))
	}

	for entry in a.bad_free_array {
		fmt.eprintfln("%v: Bad free of %p", entry.location, entry.memory)
		leaks = true
	}

	mem.tracking_allocator_clear(a)
	return leaks
}
