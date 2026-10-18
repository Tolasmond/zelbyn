#+build linux, darwin, freebsd, openbsd, netbsd
package bench

import "core:sys/posix"

// The page faults this process has taken so far, minor and major.
page_faults :: proc() -> int {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) != .OK do return -1
	return int(ru.ru_minflt + ru.ru_majflt)
}
