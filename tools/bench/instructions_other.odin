#+build !linux
package bench

// Instructions are counted only on Linux.
Instruction_Counters :: struct {}

open_instruction_counters :: proc() -> Instruction_Counters {return {}}

close_instruction_counters :: proc(c: ^Instruction_Counters) {}

instructions :: proc(c: ^Instruction_Counters) -> i64 {return -1}
