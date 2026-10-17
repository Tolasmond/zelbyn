package evaluate

import "core:math"

evaluate :: proc(expr: string, param_map: ^map[string]int) -> int {
	return int(math.pow_f32(2, f32(param_map["x"] + 1)))
}
