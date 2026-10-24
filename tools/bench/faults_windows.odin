#+build windows
package bench

import win "core:sys/windows"

// The page faults this process has taken so far, soft and hard.
page_faults :: proc() -> int {
	counters: win.PROCESS_MEMORY_COUNTERS
	counters.cb = size_of(counters)
	if !win.GetProcessMemoryInfo(win.GetCurrentProcess(), &counters, counters.cb) do return -1
	return int(counters.PageFaultCount)
}
