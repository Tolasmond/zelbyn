package tests

import dat "../gnrcrdr/data"
import mdat "../gnrcrdr/metadata"
import "core:testing"

// Returns the node for field id, searching depth first from node; nil if
// there is none.
find_node :: proc(node: ^mdat.Node, id: int) -> ^mdat.Node {
	if node == nil || node.id == id do return node
	for child in node.children {
		if found := find_node(child, id); found != nil do return found
	}
	return nil
}

@(private = "file")
count_nodes :: proc(node: ^mdat.Node, seen: ^map[^mdat.Node]bool, edges: ^int) {
	if node in seen do return
	seen[node] = true
	edges^ += len(node.children)
	for child in node.children do count_nodes(child, seen, edges)
}

@(test)
plan_root :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	testing.expect_value(t, ff.name, "GIF89a")
	root := ff.root
	if !testing.expect(t, root != nil, "no root") do return
	testing.expect_value(t, root.id, 5000)
	testing.expect_value(t, root.name, "GIF89a")
	testing.expect_value(t, root.type, dat.Data_Type.Set)
	testing.expect_value(t, root.count.(mdat.Fixed_Count) or_else {-1}, mdat.Fixed_Count{1})

	want := [?]int{5001, 5002, 5003, 5013, 5017, 5068}
	if !testing.expect_value(t, len(root.children), len(want)) do return
	for child, i in root.children {
		testing.expectf(t, child.id == want[i], "child %v is %v, want %v", i, child.id, want[i])
	}

	// every field reachable from the root has one node, and every Parent row
	// of format 1 is one edge
	seen := make(map[^mdat.Node]bool, context.temp_allocator)
	edges := 0
	count_nodes(root, &seen, &edges)
	testing.expect_value(t, len(seen), 59)
	testing.expect_value(t, edges, 74)

	// one node per SetHelper row of format 1 has a computed count or length
	computed := 0
	for node in seen {
		_, fixed := node.count.(mdat.Fixed_Count)
		_, rule_length := node.length.(mdat.Rule_Length)
		if !fixed || rule_length do computed += 1
	}
	testing.expect_value(t, computed, 14)
}

@(test)
plan_fixed_fields :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	signature := find_node(ff.root, 5001)
	if testing.expect(t, signature != nil, "no Signature node") {
		testing.expect_value(t, signature.type, dat.Data_Type.String)
		testing.expect_value(t, signature.count.(mdat.Fixed_Count) or_else {-1}, mdat.Fixed_Count{1})
		testing.expect_value(t, signature.length, mdat.Length(mdat.Fixed_Length{3}))
	}

	width := find_node(ff.root, 5004)
	if testing.expect(t, width != nil, "no Logical Screen Width node") {
		testing.expect_value(t, width.type, dat.Data_Type.UInt16)
		testing.expect_value(t, width.count.(mdat.Fixed_Count) or_else {-1}, mdat.Fixed_Count{1})
		testing.expect_value(t, width.length, nil)
	}

	identifier := find_node(ff.root, 5048)
	if testing.expect(t, identifier != nil, "no Application Identifier node") {
		testing.expect_value(t, identifier.length, mdat.Length(mdat.Fixed_Length{8}))
	}
}

@(test)
plan_color_table_counts :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	// the flag and size bits of the packed byte 3 bytes back (GCT) or 1 byte
	// back (LCT)
	for c in ([?][2]int{{5013, -3}, {5064, -1}}) {
		node := find_node(ff.root, c[0])
		if !testing.expectf(t, node != nil, "no node %v", c[0]) do continue

		count, is_rule := node.count.(mdat.Rule_Count)
		if !testing.expectf(t, is_rule, "%v: count is %v, want a Rule_Count", c[0], node.count) do continue
		testing.expect_value(t, count.max, 256)
		testing.expect_value(t, count.rule.type, dat.Data_Type.UInt8)
		testing.expect_value(t, count.rule.flag, mdat.Peek{offset = c[1], mask = 128, shift = 7})
		testing.expect_value(t, count.rule.value, mdat.Peek{offset = c[1], mask = 7})
		testing.expect_value(t, count.rule.expression, "Pow(2, [x]+1)")
	}
}

@(test)
plan_repeats_and_markers :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	Repeat_Case :: struct {
		id:     int,
		repeat: mdat.Repeat_Count,
	}
	for c in ([?]Repeat_Case {
		{5017, {type = .UInt8, value = 59, until = true, max = 2147483647}}, // Blocks, until the trailer
		{5018, {type = .UInt8, value = 33, until = false, max = 2147483647}}, // Extensions, while an introducer follows
		{5032, {type = .UInt8, value = 0, until = true, max = 2147483647}}, // Comment Data, until the block terminator
	}) {
		node := find_node(ff.root, c.id)
		if !testing.expectf(t, node != nil, "no node %v", c.id) do continue
		repeat, is_repeat := node.count.(mdat.Repeat_Count)
		testing.expectf(t, is_repeat && repeat == c.repeat, "%v: count is %v, want %v", c.id, node.count, c.repeat)
	}

	Marker_Case :: struct {
		id:      int,
		markers: []mdat.Marker,
	}
	for c in ([?]Marker_Case {
		{5019, {{0, .UInt8, 33}, {1, .UInt8, 249}}}, // Graphic Control Extension
		{5053, {{0, .UInt8, 44}}}, // Image
	}) {
		node := find_node(ff.root, c.id)
		if !testing.expectf(t, node != nil, "no node %v", c.id) do continue

		count, is_marker := node.count.(mdat.Marker_Count)
		if !testing.expectf(t, is_marker, "%v: count is %v, want a Marker_Count", c.id, node.count) do continue
		if !testing.expect_value(t, len(count.markers), len(c.markers)) do continue
		for m, i in count.markers {
			testing.expectf(t, m == c.markers[i], "%v: marker %v is %v, want %v", c.id, i, m, c.markers[i])
		}
	}
}

@(test)
plan_sub_block_blob :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	values: ^mdat.Node
	for parent_id in ([?]int{5032, 5044, 5050, 5067}) {
		parent := find_node(ff.root, parent_id)
		if !testing.expectf(t, parent != nil && len(parent.children) == 2, "node %v missing or without 2 children", parent_id) do continue

		child := parent.children[1]
		if values == nil do values = child
		testing.expectf(t, child == values, "%v: Data Sub-Block Values is not shared", parent_id)
	}
	if values == nil do return

	testing.expect_value(t, values.id, 5052)
	testing.expect_value(t, values.type, dat.Data_Type.Blob)
	length, is_rule := values.length.(mdat.Rule_Length)
	if !testing.expectf(t, is_rule, "length is %v, want a Rule_Length", values.length) do return
	testing.expect_value(t, length.min, 0)
	testing.expect_value(t, length.max, 255)
	testing.expect_value(t, length.rule.type, dat.Data_Type.UInt8)
	testing.expect_value(t, length.rule.flag, nil)
	testing.expect_value(t, length.rule.value, mdat.Peek{offset = -1})
	testing.expect_value(t, length.rule.expression, nil)
}

@(test)
plan_bits :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	node := find_node(ff.root, 5010)
	if !testing.expect(t, node != nil, "no Logical Screen Descriptor Packed Fields node") do return

	want := [?]mdat.Bit_Field {
		{5009, "Size of Global Color Table", 0, 2, i32(0)},
		{5008, "Sort Flag", 3, 3, i32(0)},
		{5007, "Color Resolution", 4, 6, i32(0)},
		{5006, "Global Color Table Flag", 7, 7, i32(0)},
	}
	if !testing.expect_value(t, len(node.bits), len(want)) do return
	for b, i in node.bits {
		testing.expectf(t, b == want[i], "bit field %v is %v, want %v", i, b, want[i])
	}

	for id in ([?]int{5023, 5060}) {
		n := find_node(ff.root, id)
		testing.expectf(t, n != nil && len(n.bits) == (id == 5023 ? 3 : 4), "%v: packed fields missing", id)
	}
	testing.expect_value(t, len(find_node(ff.root, 5011).bits), 0)
}

@(test)
plan_defaults :: proc(t: ^testing.T) {
	ff: mdat.File_Format
	defer mdat.destroy_file_format(&ff)
	if !load_gif(t, &ff) do return

	Default_Case :: struct {
		id:    int,
		value: mdat.Scalar,
	}
	for c in ([?]Default_Case {
		{5020, u8(33)}, // Extension Introducer
		{5068, u8(59)}, // Trailer
		{5029, u8(0)}, // Block Terminator
		{5004, u16(0)}, // Logical Screen Width
		{5001, nil}, // Signature: a String without a default
		{5003, nil}, // Logical Screen Descriptor: a Set
		{5052, nil}, // Data Sub-Block Values: a Blob
	}) {
		node := find_node(ff.root, c.id)
		if !testing.expectf(t, node != nil, "no node %v", c.id) do continue
		testing.expectf(t, node.default_value == c.value, "%v: default is %v (%T), want %v (%T)", c.id, node.default_value, node.default_value, c.value, c.value)
	}
}
