// One cold measurement of zelbyn: in a fresh process, compiles a schema
// from its file, reads the input, decodes it and writes the JSON dump to
// memory, once each, and prints how long each phase took. bench.py builds it
// and runs it in a new process for every measurement; run that rather than
// this.
//
//     bench_oneshot <schema.ksy> <file> [--spans]
//     bench_oneshot --start-only
//
// Prints one line of name=value pairs: compile_us, read_us, decode_us and
// json_us; compile_ins, read_ins, decode_ins and json_ins, the instructions
// each phase retired in user space (-1 where they cannot be counted: off
// Linux, or where perf_event_paranoid forbids it); faults, the page faults
// taken during the decode (-1 where the platform cannot count them);
// tree_bytes, the bytes the tree's arena handed out, which do not include the
// input; and input_bytes. With --spans the tree records the span of each
// value. With --start-only it exits at once, so that bench.py can time
// starting a process.
package bench

import arn "../../zelbyn/arena"
import dmp "../../zelbyn/dump"
import fld "../../zelbyn/field"
import ksy "../../zelbyn/ksy"
import mdata "../../zelbyn/metadata"
import rdr "../../zelbyn/reader"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--start-only" do return
	spans := len(os.args) == 4 && os.args[3] == "--spans"
	if len(os.args) != 3 && !spans {
		fmt.eprintln("usage: bench_oneshot <schema.ksy> <file> [--spans] | --start-only")
		os.exit(2)
	}
	schema, path := os.args[1], os.args[2]

	counters := open_instruction_counters()
	defer close_instruction_counters(&counters)

	p := begin_phase(&counters)
	ff: mdata.File_Format
	if err := ksy.read_file_format(schema, &ff); err.kind != .None {
		fmt.eprintfln("%s:%v:%v: %v: %s", schema, err.line, err.column, err.kind, err.message)
		os.exit(1)
	}
	compile, compile_ins := end_phase(&counters, p)

	p = begin_phase(&counters)
	data, read_err := os.read_entire_file(path, context.allocator)
	read, read_ins := end_phase(&counters, p)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", path, read_err)
		os.exit(1)
	}

	faults_before := page_faults()
	tree: fld.Value_Tree
	p = begin_phase(&counters)
	_, err := rdr.read_from_bytes(data, &ff, &tree, spans)
	decode, decode_ins := end_phase(&counters, p)
	faults := page_faults()
	if err.kind != .None {
		fmt.eprintfln("%s: %v at 0x%08X in %s", path, err.kind, err.offset, err.path)
		os.exit(1)
	}
	if faults_before >= 0 && faults >= 0 {
		faults -= faults_before
	} else {
		faults = -1
	}

	out := strings.builder_make()
	p = begin_phase(&counters)
	werr := dmp.write_json(strings.to_writer(&out), &ff, &tree)
	json, json_ins := end_phase(&counters, p)
	if werr != .None {
		fmt.eprintfln("%s: writing JSON: %v", path, werr)
		os.exit(1)
	}

	tree_bytes := arn.arena_used(&tree.arena)

	fmt.printfln(
		"compile_us=%.1f read_us=%.1f decode_us=%.1f json_us=%.1f compile_ins=%v read_ins=%v decode_ins=%v json_ins=%v faults=%v tree_bytes=%v input_bytes=%v",
		time.duration_microseconds(compile),
		time.duration_microseconds(read),
		time.duration_microseconds(decode),
		time.duration_microseconds(json),
		compile_ins,
		read_ins,
		decode_ins,
		json_ins,
		faults,
		tree_bytes,
		len(data),
	)
}

Phase :: struct {
	instructions: i64,
	start:        time.Tick,
}

// Starts timing a phase and counting its instructions. The counters are read
// outside the time, which they would add a system call to, and the clock
// inside the count, where it adds the same few instructions to every phase.
begin_phase :: proc(c: ^Instruction_Counters) -> Phase {
	ins := instructions(c)
	return {instructions = ins, start = time.tick_now()}
}

// The time the phase took, and the instructions it retired, or -1 if they
// cannot be counted.
end_phase :: proc(c: ^Instruction_Counters, p: Phase) -> (time.Duration, i64) {
	d := time.tick_since(p.start)
	ins := instructions(c)
	if ins < 0 || p.instructions < 0 do return d, -1
	return d, ins - p.instructions
}
