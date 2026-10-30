#+build linux
package bench

import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

PMU_DEVICES :: "/sys/bus/event_source/devices"

// Counters of the instructions this process retires in user space, one per
// kind of core: a hybrid CPU has a PMU for each (cpu_core and cpu_atom), and
// a counter of one counts nothing while the process runs on the other. They
// are pinned: the kernel puts them on their PMU before any event that is not,
// so other users of the PMU cannot take turns with them and leave part of a
// phase uncounted. One that cannot be put on it, as pinned events of others
// hold every counter, is in error, and reads of it give nothing until it is
// closed.
Instruction_Counters :: struct {
	fds: [dynamic]linux.Fd,
}

// Opens the counters, which count from then on. None are open where the
// kernel forbids them (perf_event_paranoid above 2) or the CPU has none, or
// if the counter of any kind of core cannot be opened.
open_instruction_counters :: proc() -> (c: Instruction_Counters) {
	// The PMUs that count a core's events: `cpu`, or on a hybrid CPU those
	// that list the CPUs they serve. The generic event, which needs no PMU,
	// is enough where there is one.
	pmu_types: [dynamic]u64
	defer delete(pmu_types)
	devices, _ := os.read_all_directory_by_path(PMU_DEVICES, context.temp_allocator)
	for device in devices {
		dir := strings.concatenate({PMU_DEVICES, "/", device.name}, context.temp_allocator)
		if device.name != "cpu" && !os.exists(strings.concatenate({dir, "/cpus"}, context.temp_allocator)) do continue
		text, err := os.read_entire_file(strings.concatenate({dir, "/type"}, context.temp_allocator), context.temp_allocator)
		if err != nil do return
		type, ok := strconv.parse_u64(strings.trim_space(string(text)))
		if !ok do return
		append(&pmu_types, type)
	}
	if len(pmu_types) <= 1 {
		clear(&pmu_types)
		append(&pmu_types, 0)
	}

	for type in pmu_types {
		attr := linux.Perf_Event_Attr {
			type = .HARDWARE,
			size = size_of(linux.Perf_Event_Attr),
			flags = {.Pinned, .Exclude_Kernel, .Exclude_HV},
		}
		// The PMU's type in the high half of the event's selects it.
		attr.config.other = type << 32 | u64(linux.Perf_Hardware_Id.INSTRUCTIONS)
		fd, err := linux.perf_event_open(&attr, 0, -1, -1, {.FD_CLOEXEC})
		if err != .NONE {
			close_instruction_counters(&c)
			return
		}
		append(&c.fds, fd)
	}
	return
}

close_instruction_counters :: proc(c: ^Instruction_Counters) {
	for fd in c.fds do linux.close(fd)
	delete(c.fds)
	c.fds = nil
}

// The instructions retired since the counters were opened, or -1 if none are
// open or one cannot be read, which a counter in error cannot.
instructions :: proc(c: ^Instruction_Counters) -> i64 {
	if len(c.fds) == 0 do return -1
	total: i64
	for fd in c.fds {
		count: u64
		n, err := linux.read(fd, mem.ptr_to_bytes(&count))
		if err != .NONE || n != size_of(count) do return -1
		total += i64(count)
	}
	return total
}
