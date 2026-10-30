package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// The name each of zelbyn's packages is imported under, everywhere: in
// zelbyn/, main.odin, tests/, tools/ and view/ (doc/arch.md, "Package
// dependencies").
@(private = "file")
IMPORT_NAMES := [?][2]string {
	{"arena", "arn"},
	{"cli", "cli"},
	{"codegen", "codegen"},
	{"data", "dat"},
	{"dump", "dmp"},
	{"expression", "expr"},
	{"field", "fld"},
	{"file", "file"},
	{"ksy", "ksy"},
	{"metadata", "mdata"},
	{"reader", "rdr"},
	{"yaml", "yml"},
}

// Every import of one of zelbyn's packages names it as IMPORT_NAMES says,
// so that a package has one name in every file.
@(test)
import_names :: proc(t: ^testing.T) {
	files := make([dynamic]string, context.temp_allocator)
	append(&files, "main.odin")
	collect :: proc(dir: string, files: ^[dynamic]string) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return
		for e in entries {
			path, _ := filepath.join({dir, e.name}, context.temp_allocator)
			if e.type == .Directory {
				// view/hnoss is a submodule, whose ../ imports are its own
				if e.name != "node_modules" && !strings.has_prefix(e.name, ".") && !(dir == "view" && e.name == "hnoss") do collect(path, files)
			} else if strings.has_suffix(e.name, ".odin") {
				append(files, path)
			}
		}
	}
	for dir in ([]string{"zelbyn", "tests", "tools", "view"}) do collect(dir, &files)

	imports := 0
	for path in files {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, err == nil, "reading %s: %v", path, err) do continue
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if !strings.has_prefix(line, "import ") do continue
			quote := strings.index_byte(line, '"')
			if quote < 0 do continue
			target := strings.trim(line[quote:], "\"")
			// zelbyn's own: ../x, ../../zelbyn/x, zelbyn/x; not core: or base:
			if strings.contains(target, ":") || !(strings.has_prefix(target, "../") || strings.has_prefix(target, "zelbyn/")) do continue
			pkg := target[strings.last_index_byte(target, '/') + 1:]
			want, known := "", false
			for n in IMPORT_NAMES do if n[0] == pkg do want, known = n[1], true
			if !testing.expectf(t, known, "%s: %s imports %q, which has no name in IMPORT_NAMES", path, line, pkg) do continue
			alias := strings.trim_space(line[len("import "):quote])
			name := alias != "" ? alias : pkg
			testing.expectf(t, name == want, "%s: %s names %s %s, not %s", path, line, pkg, name, want)
			imports += 1
		}
	}
	testing.expectf(t, imports > 50, "only %v imports of zelbyn's packages found", imports)
}
