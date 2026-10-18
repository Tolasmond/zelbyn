#+build windows
package bench

// Windows has no getrusage, so page faults are not counted.
page_faults :: proc() -> int {
	return -1
}
