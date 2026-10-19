#+build linux, darwin, freebsd, openbsd, netbsd
package file

import "core:mem"
import "core:os"
import "core:sys/posix"

// Reads the whole of the file at path into memory allocated with
// allocator, as os.read_entire_file does, but with only the system calls
// it needs: os.open also finds the file's full path and allocates a File,
// which costs a cold process more than reading a schema does. A file that
// is not a regular one, or whose size is not known, a path longer than
// the buffer for it, and an empty file are read with os.read_entire_file.
// Errors are those os would give.
@(require_results)
read_entire_file :: proc(path: string, allocator: mem.Allocator) -> (data: []byte, err: os.Error) {
	buf: [1024]byte
	if len(path) >= len(buf) do return os.read_entire_file(path, allocator)
	copy(buf[:], path)
	buf[len(path)] = 0

	fd := posix.open(cstring(raw_data(buf[:])), {.CLOEXEC})
	if fd < 0 do return nil, platform_error(posix.errno())
	defer posix.close(fd)

	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK do return nil, platform_error(posix.errno())
	if !posix.S_ISREG(st.st_mode) || st.st_size <= 0 || i64(int(st.st_size)) != i64(st.st_size) {
		return os.read_entire_file(path, allocator)
	}

	data = make([]byte, int(st.st_size), allocator) or_return
	total := 0
	for total < len(data) {
		n := posix.read(fd, raw_data(data[total:]), uint(len(data)) - uint(total))
		if n < 0 {
			if posix.errno() == .EINTR do continue
			return nil, platform_error(posix.errno())
		}
		if n == 0 do break
		total += int(n)
	}
	return data[:total], nil
}

// errno as os gives it.
@(private = "file")
platform_error :: proc(errno: posix.Errno) -> os.Error {
	#partial switch errno {
	case .EPERM, .EACCES:
		return .Permission_Denied
	case .EEXIST:
		return .Exist
	case .ENOENT:
		return .Not_Exist
	case .ETIMEDOUT:
		return .Timeout
	case .EPIPE:
		return .Broken_Pipe
	case .EBADF:
		return .Invalid_File
	case .ENOMEM:
		return .Out_Of_Memory
	case .ENOSYS:
		return .Unsupported
	}
	return os.Platform_Error(errno)
}
