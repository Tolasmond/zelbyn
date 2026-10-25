package data

// The code points of s from from up to to, a view of s, both clamped to
// its length: empty when to is not after from, and Index_Out_Of_Range when
// either is negative (Kaitai's .substring).
@(require_results)
substring :: proc(s: string, from, to: int) -> (string, Read_Error) {
	if from < 0 || to < 0 do return "", .Index_Out_Of_Range
	if to <= from do return "", .None
	start, end := len(s), len(s)
	n := 0
	for _, i in s {
		if n == from do start = i
		if n == to {
			end = i
			break
		}
		n += 1
	}
	return s[start:end], .None
}
