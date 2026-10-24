package arena

import "core:mem"
import "core:mem/virtual"

// An arena: blocks of virtual memory, reserved up front and committed as
// they are used, like virtual.Arena's growing kind, but without its mutex,
// since one thread uses each arena (a decoded tree, a compiled plan, a
// parsed YAML document). The first block reserves the size arena_init
// sets, or ARENA_BLOCK_SIZE, and that target doubles with each block; a
// block for an allocation larger than the target reserves that allocation
// instead, so it can be larger than the next block. Memory
// is handed out fresh from the operating system, so it is zero; the most
// recent allocation grows in place, as arrays do while a repeat is read.
Arena :: struct {
	block:      ^virtual.Memory_Block, // the current block; the earlier ones through prev
	block_size: uint,                  // to reserve for the next block
	prior_used: uint,                  // the bytes handed out in the blocks before block
	limit:      uint,                  // the bytes that may be handed out (arena_used), beyond which an allocation fails; 0 for no limit (arena_set_limit)
	end:        uint,                  // the offset in block that arena_make hands out memory inline up to: its committed memory, or less, where limit is reached (set_end)
}

// The least a block commits at a time. Each commit is a system call, and
// one grows the committed memory by half of it, so a small first commit
// takes several. It stays below the 2 MiB of a huge page, which Linux can
// back a large committed range with and zeroes whole on first touch.
COMMIT_SIZE :: mem.Megabyte

// The default size of the first block, when arena_init is not called.
ARENA_BLOCK_SIZE :: 4 * mem.Megabyte

// Sets the size of the first block. Optional; call it before allocating.
arena_init :: proc(a: ^Arena, first_block_size: uint) {
	assert(a.block == nil, "arena_init: the arena is in use")
	a.block_size = first_block_size
}

// a as a mem.Allocator, for dynamic arrays, maps, strings and what
// zlib.inflate allocates; its allocations are bounded by a.limit.
arena_allocator :: proc(a: ^Arena) -> mem.Allocator {
	return {allocator_proc, a}
}

// Sets the bytes a may hand out in all (arena_used), 0 for no limit. An
// allocation that would take a beyond them fails, however much memory is
// committed: the operating system commits more than is asked for.
arena_set_limit :: proc(a: ^Arena, limit: uint) {
	a.limit = limit
	if a.block != nil do set_end(a)
}

// The bytes a has handed out.
arena_used :: proc(a: ^Arena) -> uint {
	return a.block == nil ? 0 : a.prior_used + a.block.used
}

// Frees every block and resets a to the zero value. Safe on a zero arena.
arena_destroy :: proc(a: ^Arena) {
	for a.block != nil {
		prev := a.block.prev
		virtual.memory_block_dealloc(a.block)
		a.block = prev
	}
	a^ = {}
}

// Allocates n values of T, zero and aligned for T, without going through
// mem.Allocator: the decoder's allocations. A block's committed memory is
// handed out inline, up to a.limit (a.end); only committing more, a new
// block, or reaching the limit, takes a call. Fails with Out_Of_Memory when the allocation would
// take a beyond its limit, when the operating system has no memory left,
// or when n values of T would not fit in the address space.
@(require_results)
arena_make :: #force_inline proc(a: ^Arena, $T: typeid, n: int) -> (values: []T, err: mem.Allocator_Error) {
	if n <= 0 do return nil, nil
	if uint(n) > max(uint) / size_of(T) do return nil, .Out_Of_Memory
	size, alignment := uint(n) * size_of(T), uint(align_of(T))
	if b := a.block; b != nil {
		top := uintptr(b.base) + uintptr(b.used)
		start := uint((top + uintptr(alignment - 1)) &~ uintptr(alignment - 1) - uintptr(b.base))
		if start + size <= a.end {
			b.used = start + size
			return ([^]T)(&b.base[start])[:n], nil
		}
	}
	bytes := arena_alloc(a, size, alignment) or_return
	return ([^]T)(raw_data(bytes))[:n], nil
}

// Whether a can hand out extra bytes more, within a.limit.
@(private = "file")
within_limit :: #force_inline proc(a: ^Arena, extra: uint) -> bool {
	return a.limit == 0 || (extra <= a.limit && arena_used(a) <= a.limit - extra)
}

// Sets a.end, which bounds arena_make's inline path, from the current
// block's committed memory, as it changes, and a.limit: virtual commits
// half as much again as the block holds, which would otherwise take a
// beyond its limit.
@(private = "file")
set_end :: proc(a: ^Arena) {
	a.end = a.block.committed
	if a.limit != 0 do a.end = min(a.end, a.limit > a.prior_used ? a.limit - a.prior_used : 0)
}

// size bytes aligned to alignment, from the current block, or a block
// added; fails when they would take a beyond a.limit.
@(private = "file", require_results)
arena_alloc :: proc(a: ^Arena, size, alignment: uint) -> (data: []byte, err: mem.Allocator_Error) {
	if !within_limit(a, size + alignment) do return nil, .Out_Of_Memory
	if a.block != nil {
		data, err = virtual.alloc_from_memory_block(a.block, size, alignment, COMMIT_SIZE)
		set_end(a)
		if err != .Out_Of_Memory do return
	}

	if a.block_size == 0 do a.block_size = ARENA_BLOCK_SIZE
	reserve := max(a.block_size, size + alignment)
	// a block reserves no more than the limit leaves, but what is asked
	if a.limit != 0 {
		left := a.limit > arena_used(a) ? a.limit - arena_used(a) : 0
		reserve = max(min(reserve, left), size + alignment)
	}
	block := virtual.memory_block_alloc(0, reserve) or_return
	if a.block != nil do a.prior_used += a.block.used
	block.prev = a.block
	a.block = block
	a.block_size *= 2
	data, err = virtual.alloc_from_memory_block(a.block, size, alignment, COMMIT_SIZE)
	set_end(a)
	return
}

@(private = "file")
allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	data: []byte,
	err: mem.Allocator_Error,
) {
	a := (^Arena)(allocator_data)

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 do return nil, nil
		return arena_alloc(a, uint(size), uint(alignment))
	case .Resize, .Resize_Non_Zeroed:
		old := ([^]byte)(old_memory)
		switch {
		case old == nil:
			if size == 0 do return nil, nil
			return arena_alloc(a, uint(size), uint(alignment))
		case size <= old_size:
			return old[:size], nil
		}

		// the most recent allocation grows in place when its block has room
		if b := a.block; b != nil && uintptr(old) & uintptr(alignment - 1) == 0 {
			start := uint(uintptr(old) - uintptr(b.base))
			if start < b.used && start + uint(old_size) == b.used && start + uint(size) <= b.reserved {
				if !within_limit(a, uint(size - old_size)) do return nil, .Out_Of_Memory
				_, err = virtual.alloc_from_memory_block(b, uint(size - old_size), 1, COMMIT_SIZE)
				set_end(a)
				return err == nil ? old[:size] : nil, err
			}
		}

		data = arena_alloc(a, uint(size), uint(alignment)) or_return
		copy(data, old[:old_size])
		return data, nil
	case .Free, .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		if set := (^mem.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}
