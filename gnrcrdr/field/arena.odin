package field

import "core:mem"
import "core:mem/virtual"

// The arena of a decoded tree: blocks of virtual memory, reserved up front
// and committed as they are used, like virtual.Arena's growing kind, but
// without its mutex, since one decode on one thread builds a tree. Each
// block reserves twice the one before. Memory is handed out fresh from the
// operating system, so it is zero; the most recent allocation grows in
// place, as arrays do while a repeat is read.
Tree_Arena :: struct {
	block:      ^virtual.Memory_Block, // the current block; the earlier ones through prev
	block_size: uint,                  // to reserve for the next block
}

// The default size of the first block, when tree_arena_init is not called.
TREE_ARENA_BLOCK_SIZE :: 4 * mem.Megabyte

// Sets the size of the first block. Optional; call it before allocating.
tree_arena_init :: proc(a: ^Tree_Arena, first_block_size: uint) {
	assert(a.block == nil, "tree_arena_init: the arena is in use")
	a.block_size = first_block_size
}

tree_arena_allocator :: proc(a: ^Tree_Arena) -> mem.Allocator {
	return {tree_arena_allocator_proc, a}
}

// Frees every block and resets a to the zero value. Safe on a zero arena.
tree_arena_destroy :: proc(a: ^Tree_Arena) {
	for a.block != nil {
		prev := a.block.prev
		virtual.memory_block_dealloc(a.block)
		a.block = prev
	}
	a^ = {}
}

// Allocates n values of T, zero and aligned for T, without going through
// mem.Allocator: the decoder's allocations. A block's committed memory is
// handed out inline; only committing more, or a new block, takes a call.
// Panics when the operating system has no memory left.
tree_arena_make :: #force_inline proc(a: ^Tree_Arena, $T: typeid, n: int) -> []T {
	if n <= 0 do return nil
	size, alignment := uint(n) * size_of(T), uint(align_of(T))
	if b := a.block; b != nil {
		top := uintptr(b.base) + uintptr(b.used)
		start := uint((top + uintptr(alignment - 1)) &~ uintptr(alignment - 1) - uintptr(b.base))
		if start + size <= b.committed {
			b.used = start + size
			return ([^]T)(&b.base[start])[:n]
		}
	}
	data, err := tree_arena_alloc(a, size, alignment)
	if err != nil do panic("tree arena: out of memory")
	return ([^]T)(raw_data(data))[:n]
}

@(private = "file", require_results)
tree_arena_alloc :: proc(a: ^Tree_Arena, size, alignment: uint) -> (data: []byte, err: mem.Allocator_Error) {
	if a.block != nil {
		data, err = virtual.alloc_from_memory_block(a.block, size, alignment)
		if err != .Out_Of_Memory do return
	}

	if a.block_size == 0 do a.block_size = TREE_ARENA_BLOCK_SIZE
	block := virtual.memory_block_alloc(0, max(a.block_size, size + alignment)) or_return
	block.prev = a.block
	a.block = block
	a.block_size *= 2
	return virtual.alloc_from_memory_block(a.block, size, alignment)
}

@(private = "file")
tree_arena_allocator_proc :: proc(
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
	a := (^Tree_Arena)(allocator_data)

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 do return nil, nil
		return tree_arena_alloc(a, uint(size), uint(alignment))
	case .Resize, .Resize_Non_Zeroed:
		old := ([^]byte)(old_memory)
		switch {
		case old == nil:
			if size == 0 do return nil, nil
			return tree_arena_alloc(a, uint(size), uint(alignment))
		case size <= old_size:
			return old[:size], nil
		}

		// the most recent allocation grows in place when its block has room
		if b := a.block; b != nil && uintptr(old) & uintptr(alignment - 1) == 0 {
			start := uint(uintptr(old) - uintptr(b.base))
			if start < b.used && start + uint(old_size) == b.used && start + uint(size) <= b.reserved {
				_ = virtual.alloc_from_memory_block(b, uint(size - old_size), 1) or_return
				return old[:size], nil
			}
		}

		data = tree_arena_alloc(a, uint(size), uint(alignment)) or_return
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
