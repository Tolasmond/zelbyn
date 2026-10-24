#+build linux, darwin, freebsd, openbsd, netbsd
package tests

import arn "../zelbyn/arena"
import "../zelbyn/file"
import "core:c"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// The reads the injected read makes before it fails: each of them reads
// half of what it is asked (at least a byte), from the file, so that a
// failure can follow a partial read. Thread-local, as tests run on several
// threads.
@(private = "file", thread_local)
reads_before_failure: int

// The errno the injected read fails with; .EINTR fails once, and the reads
// after it read all they are asked.
@(private = "file", thread_local)
failure: posix.Errno

@(private = "file")
injected_read :: proc "c" (fd: posix.FD, buf: [^]byte, nbyte: c.size_t) -> c.ssize_t {
	if reads_before_failure == 0 {
		reads_before_failure = -1
		posix.errno(failure)
		return -1
	}
	if reads_before_failure < 0 do return posix.read(fd, buf, nbyte)
	reads_before_failure -= 1
	return posix.read(fd, buf, max(nbyte / 2, 1))
}

// A read of a schema that fails once its buffer is allocated, at once or
// after partial reads, gives the error the system gave, and leaves nothing
// allocated; one interrupted (EINTR) reads it all. With an arena, as a
// schema's imports are read, whose free does nothing and fails, the error
// is still the system's, and the arena still allocates: the schema is read
// into it again.
@(test)
file_read_failure_frees :: proc(t: ^testing.T) {
	content := "meta:\n  id: t\nseq:\n  - id: a\n    type: u1\n  - id: b\n    type: u1\n"
	f, create_err := os.create_temp_file("", "zelbyn_test_*.ksy")
	if !testing.expectf(t, create_err == nil, "creating a temporary file: %v", create_err) do return
	path := strings.clone(os.name(f))
	defer delete(path)
	_, write_err := os.write(f, transmute([]byte)content)
	os.close(f)
	defer {
		remove_err := os.remove(path)
		testing.expectf(t, remove_err == nil, "removing %s: %v", path, remove_err)
	}
	if !testing.expectf(t, write_err == nil, "writing %s: %v", path, write_err) do return

	Case :: struct {
		name:          string,
		reads_before:  int,
		failure:       posix.Errno,
		want:          os.Error,
	}
	cases := [?]Case {
		{"at once", 0, .EIO, os.Platform_Error(posix.Errno.EIO)},
		{"after a partial read", 1, .EIO, os.Platform_Error(posix.Errno.EIO)},
		{"after two partial reads", 2, .EIO, os.Platform_Error(posix.Errno.EIO)},
		{"mapped as os maps it", 1, .EACCES, io.Error.Permission_Denied},
		{"interrupted", 1, .EINTR, nil},
	}
	for c in cases {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		allocator := mem.tracking_allocator(&track)

		reads_before_failure, failure = c.reads_before, c.failure
		data, err := file.read_entire_file(path, allocator, injected_read)
		testing.expectf(t, err == c.want, "%s: got %v, want %v", c.name, err, c.want)
		if c.want == nil {
			testing.expectf(t, string(data) == content, "%s: got %q", c.name, data)
			delete(data, allocator)
		} else {
			testing.expectf(t, data == nil, "%s: data returned with the error", c.name)
		}
		// the buffer was allocated before the read failed, and is freed
		testing.expectf(t, track.total_allocation_count > 0, "%s: nothing was allocated", c.name)
		testing.expectf(t, len(track.allocation_map) == 0, "%s: %v allocations left", c.name, len(track.allocation_map))
		testing.expectf(t, len(track.bad_free_array) == 0, "%s: %v bad frees", c.name, len(track.bad_free_array))
		mem.tracking_allocator_destroy(&track)

		a: arn.Arena
		reads_before_failure, failure = c.reads_before, c.failure
		data, err = file.read_entire_file(path, arn.arena_allocator(&a), injected_read)
		testing.expectf(t, err == c.want, "%s (arena): got %v, want %v", c.name, err, c.want)
		testing.expectf(t, (data == nil) == (c.want != nil), "%s (arena): got %q", c.name, data)
		again, again_err := file.read_entire_file(path, arn.arena_allocator(&a))
		testing.expectf(t, again_err == nil && string(again) == content, "%s (arena): read again: %v, %q", c.name, again_err, again)
		arn.arena_destroy(&a)
	}
}
