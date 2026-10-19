#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package file

import "core:mem"
import "core:os"

// Reads the whole of the file at path into memory allocated with
// allocator: os.read_entire_file.
@(require_results)
read_entire_file :: proc(path: string, allocator: mem.Allocator) -> (data: []byte, err: os.Error) {
	return os.read_entire_file(path, allocator)
}
