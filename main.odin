package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import fld "gnrcrdr/field"
import mdat "gnrcrdr/metadata"
import rdr "gnrcrdr/reader"
import sql "gnrcrdr/sqlite"

main :: proc() {
	context.logger = log.create_console_logger()

	exit_code := run_tracked()

	os.exit(exit_code) // os.exit skips defers: run_tracked has already cleaned up
}

// Calls run. In debug builds (-debug) it runs under a tracking allocator and
// reports leaks and bad frees, either of which turns exit code 0 into 1.
run_tracked :: proc() -> int {
	when ODIN_DEBUG {
		tracking_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracking_allocator, context.allocator)
		tracking_allocator.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		context.allocator = mem.tracking_allocator(&tracking_allocator)

		exit_code := run()

		if reset_tracking_allocator(&tracking_allocator) && exit_code == 0 {
			exit_code = 1
		}
		mem.tracking_allocator_destroy(&tracking_allocator)
		return exit_code
	} else {
		return run()
	}
}

// Loads the GIF89a format and decodes the sample file. Errors are reported
// on stderr. Returns 0 on success, 1 on any error.
run :: proc() -> int {
	file_format: mdat.File_Format
	defer mdat.destroy_file_format(&file_format)

	db_path := "data/Gif89aMetadata.sqlite3"
	format_id := 1
	gif_path := "data/855.gif"

	log.debugf("reading %v", db_path)

	load_err := sql.read_file_format(db_path, format_id, &file_format)
	defer sql.destroy_load_error(&load_err)

	if load_err.kind != .None {
		fmt.eprintfln(
			"error: loading format %v from %s: %v (%v, table %s): %s",
			format_id,
			db_path,
			load_err.kind,
			load_err.code,
			load_err.table,
			load_err.message)
		return 1
	}

	log.debug("populating field value array")

	tree: fld.Value_Tree
	// the tree may be partially filled after a parse error; free it either way
	defer fld.destroy_value_tree(&tree)

	_, parse_err := rdr.read(gif_path, &file_format, &tree)
	defer rdr.destroy_parse_error(&parse_err)

	if parse_err.kind == .File_Read_Failed {
		fmt.eprintfln("error: cannot read %s: %v", gif_path, parse_err.os_error)
		return 1
	} else if parse_err.kind != .None {
		fmt.eprintfln("error: %v at 0x%08X in %s", parse_err.kind, parse_err.offset, parse_err.path)
		return 1
	}

	return 0
}

reset_tracking_allocator :: proc(a: ^mem.Tracking_Allocator) -> bool {
	leaks := false

	if len(a.allocation_map) != 0 {
		fmt.printfln("%v leaks found!", len(a.allocation_map))
	}

	for _, value in a.allocation_map {
		fmt.printfln("%v: Leaked %v bytes", value.location, value.size)
		leaks = true
	}

	if len(a.bad_free_array) != 0 {
		fmt.printfln("%v bad frees found!", len(a.bad_free_array))
	}

	for entry in a.bad_free_array {
		fmt.printfln("%v: Bad free of %p", entry.location, entry.memory)
		leaks = true
	}

	mem.tracking_allocator_clear(a)
	return leaks
}
