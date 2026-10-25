package data

import "base:intrinsics"
import "core:math"

// The integers of a Kaitai expression: from min(int) to max(u64), exactly.
// Every integer of a schema has this range, and every integer operation the
// rules of the procedures below, which the decoder (through
// metadata.int_binary and int_unary), the compiler, when it folds a
// constant, and generated code all use: / and % round toward negative
// infinity, as in Python and so Kaitai's Python runtime; a division by
// zero, a shift by a negative amount or by 64 or more, and a result outside
// the range fail, with Division_By_Zero, Invalid_Shift and
// Integer_Overflow. Each takes integers within the range.
INT_MIN :: i128(min(int))
INT_MAX :: i128(max(u64))

// n, or Integer_Overflow when it is outside INT_MIN to INT_MAX.
@(require_results)
int_in_range :: #force_inline proc(n: i128) -> (i128, Read_Error) {
	if n < INT_MIN || n > INT_MAX do return 0, .Integer_Overflow
	return n, .None
}

@(require_results)
int_mul :: proc(a, b: i128) -> (i128, Read_Error) {
	n, overflow := intrinsics.overflow_mul(a, b)
	if overflow do return 0, .Integer_Overflow
	return int_in_range(n)
}

@(require_results)
int_add :: proc(a, b: i128) -> (i128, Read_Error) {
	return int_in_range(a + b)
}

@(require_results)
int_sub :: proc(a, b: i128) -> (i128, Read_Error) {
	return int_in_range(a - b)
}

@(require_results)
int_div :: proc(a, b: i128) -> (i128, Read_Error) {
	if b == 0 do return 0, .Division_By_Zero
	n := a / b
	if a % b != 0 && (a < 0) != (b < 0) do n -= 1
	return int_in_range(n)
}

// With the sign of the divisor.
@(require_results)
int_mod :: proc(a, b: i128) -> (i128, Read_Error) {
	if b == 0 do return 0, .Division_By_Zero
	return int_in_range(b == -1 ? 0 : a %% b)
}

@(require_results)
int_shl :: proc(a, b: i128) -> (i128, Read_Error) {
	if b < 0 || b > 63 do return 0, .Invalid_Shift
	// below 2^64 shifted by at most 63, within an i128
	return int_in_range(a << uint(b))
}

// Arithmetic.
@(require_results)
int_shr :: proc(a, b: i128) -> (i128, Read_Error) {
	if b < 0 || b > 63 do return 0, .Invalid_Shift
	return int_in_range(a >> uint(b))
}

@(require_results)
int_and :: proc(a, b: i128) -> (i128, Read_Error) {
	return int_in_range(a & b)
}

@(require_results)
int_xor :: proc(a, b: i128) -> (i128, Read_Error) {
	return int_in_range(a ~ b)
}

@(require_results)
int_or :: proc(a, b: i128) -> (i128, Read_Error) {
	return int_in_range(a | b)
}

@(require_results)
int_neg :: proc(a: i128) -> (i128, Read_Error) {
	return int_in_range(-a)
}

@(require_results)
int_not :: proc(a: i128) -> (i128, Read_Error) {
	return int_in_range(~a)
}

// n as a size, count or offset: Integer_Overflow above max(int).
@(require_results)
int_size :: #force_inline proc(n: i128) -> (int, Read_Error) {
	if n > i128(max(int)) do return 0, .Integer_Overflow
	return int(n), .None
}

// The integer part of f, rounded toward zero: Integer_Overflow when it is
// beyond INT_MIN to INT_MAX, or f is not a number (Kaitai's .to_i of a
// float).
@(require_results)
float_to_int :: proc(f: f64) -> (n: i128, err: Read_Error) {
	t := math.trunc(f)
	// -2^63 fits, and so does any below 2^64; NaN fails both
	if !(t >= -9223372036854775808.0 && t < 18446744073709551616.0) do return 0, .Integer_Overflow
	if t >= 9223372036854775808.0 do return i128(u64(t)), .None
	return i128(int(t)), .None
}

// The decimal integer s is, with an optional + or -: Invalid_Number when it
// is not one, and Integer_Overflow when it is beyond INT_MIN to INT_MAX
// (Kaitai's .to_i of a string).
@(require_results)
string_to_int :: proc(s: string) -> (n: i128, err: Read_Error) {
	digits := s
	negative := false
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {
		negative = digits[0] == '-'
		digits = digits[1:]
	}
	if len(digits) == 0 do return 0, .Invalid_Number
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' do return 0, .Invalid_Number
		// once beyond max(u64), n stays beyond it, and so within an i128
		if n <= i128(max(u64)) do n = n * 10 + i128(c - '0')
	}
	return int_in_range(negative ? -n : n)
}

// The decimal digits of n, with a - when it is negative, written at the end
// of buf, which holds those of min(int) and of max(u64) (Kaitai's .to_s of
// an integer): a view of buf.
int_digits :: proc(buf: ^[20]byte, n: i128) -> string {
	i := len(buf)
	u := u64(n < 0 ? -n : n)
	for {
		i -= 1
		buf[i] = '0' + byte(u % 10)
		u /= 10
		if u == 0 do break
	}
	if n < 0 {
		i -= 1
		buf[i] = '-'
	}
	return string(buf[i:])
}
