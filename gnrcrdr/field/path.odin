package field

import mdat "../metadata"
import "core:strings"

Path_Pair :: struct {
	id: int,
	index: int,
}

Path :: struct {
	pairs: [dynamic]Path_Pair,
}

destroy_path :: proc(path: ^Path) {
	delete(path.pairs)
}

appendPathPair :: proc(path: ^Path, pair: Path_Pair) {
	append(&path.pairs, pair)
}

popPathPair :: proc(path: ^Path) {
	pop(&path.pairs)
}

create_path_string :: proc(path: ^Path, node: ^mdat.Field_Metadata_Tree_Node) -> string {

	if len(path.pairs) == 0 do return ""

	path_name_map := mdat.create_path_name_map(node)
	defer delete(path_name_map)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for i in 0..<len(path.pairs) {

		if (i != 0) {
			strings.write_string(&builder, ".")
		}

		path_pair := &path.pairs[i]

		strings.write_string(&builder, path_name_map[path_pair.id])
		if (path_pair.index != 0) {
			strings.write_string(&builder, "[")
			strings.write_int(&builder, path_pair.index)
			strings.write_string(&builder, "]")
		}
	}

	return strings.clone(strings.to_string(builder))
}
