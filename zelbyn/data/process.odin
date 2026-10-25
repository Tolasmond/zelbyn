package data

import "base:runtime"
import bts "core:bytes"
import "core:compress/zlib"
import "core:slice"

// raw, the bytes of an element with process: zlib (a zlib stream, with its
// header and checksum), decompressed with allocator, which also holds what
// decompressing allocates: Decompression_Failed when they are not a zlib
// stream, and Memory_Limit when allocator has no room.
@(require_results)
inflate :: proc(raw: []byte, allocator: runtime.Allocator) -> (processed: []byte, err: Read_Error) {
	// inflate reports some of the allocations that fail as another error
	recorder := Failure_Recorder{allocator = allocator}
	recording := runtime.Allocator{failure_recorder_proc, &recorder}
	buf: bts.Buffer
	bts.buffer_init_allocator(&buf, 0, max(4 * len(raw), 64), recording)
	inflate_err: zlib.Error
	{
		context.allocator = recording
		context.temp_allocator = recording
		inflate_err = zlib.inflate(raw, &buf)
	}
	if _, out_of_memory := inflate_err.(runtime.Allocator_Error); out_of_memory || recorder.failed do return nil, .Memory_Limit
	if inflate_err != nil do return nil, .Decompression_Failed
	return bts.buffer_to_bytes(&buf), .None
}

// An allocator, as inflate gives zlib.inflate the one it is given, that
// records whether an allocation through it failed for want of memory.
@(private = "file")
Failure_Recorder :: struct {
	allocator: runtime.Allocator,
	failed:    bool,
}

@(private = "file")
failure_recorder_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	data: []byte,
	err: runtime.Allocator_Error,
) {
	r := (^Failure_Recorder)(allocator_data)
	data, err = r.allocator.procedure(r.allocator.data, mode, size, alignment, old_memory, old_size, loc)
	if err == .Out_Of_Memory do r.failed = true
	return
}

// bytes without pad at their end, and cut at the first terminator, which
// they keep with include (Kaitai's pad-right and terminator, with a size).
trim :: proc(bytes: []byte, pad: Maybe(u8), terminator: Maybe(u8), include: bool) -> []byte {
	bytes := bytes
	if p, padded := pad.?; padded {
		for len(bytes) > 0 && bytes[len(bytes) - 1] == p do bytes = bytes[:len(bytes) - 1]
	}
	if t, terminated := terminator.?; terminated {
		if i, found := slice.linear_search(bytes, t); found do bytes = bytes[:i + int(include)]
	}
	return bytes
}

// Bits low through high of raw, an integer reinterpreted as unsigned, at
// the low end of the result (the -bits extension).
bits_of :: proc(raw: u64, low, high: int) -> u64 {
	width := uint(high - low + 1)
	bits := raw >> uint(low)
	if width < 64 do bits &= (1 << width) - 1
	return bits
}
