// Compiles every .ksy file under the directory named on the command line
// but those of EXCLUDED, with that directory as the import path, and
// prints one tab-separated line for each, in path order: OK and its path,
// or ERR, its path, the error's kind, where it is (file:line:column, the
// file relative to the directory) and its message. Not part of zelbyn's
// build: check.py builds and runs it.
package ksy_corpus

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import ksy "../../zelbyn/ksy"
import mdata "../../zelbyn/metadata"

// The files left out, relative to the directory: zelbyn keeps nothing of
// GIF, whose sample files it had no licenses for. tools/yaml_corpus leaves
// out the same.
EXCLUDED :: []string{"image/gif.ksy"}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: ksy_corpus <dir>")
		os.exit(2)
	}
	root := os.args[1]

	out: bufio.Writer
	bufio.writer_init(&out, os.to_stream(os.stdout))
	defer bufio.writer_destroy(&out)
	w := bufio.writer_to_writer(&out)

	paths: [dynamic]string
	walk(root, &paths)
	slice.sort(paths[:])
	for path in paths {
		if slice.contains(EXCLUDED, relative(root, path)) do continue
		ff: mdata.File_Format
		err := ksy.read_file_format(path, &ff, {root})
		if err.kind == .None {
			fmt.wprintfln(w, "OK\t%s", relative(root, path))
		} else {
			fmt.wprintfln(w, "ERR\t%s\t%v\t%s:%d:%d\t%s", relative(root, path), err.kind, relative(root, err.path), err.line, err.column, one_line(err.message))
		}
		ksy.destroy_error(&err)
		mdata.destroy_file_format(&ff)
	}
	bufio.writer_flush(&out)
}

// Appends the path of every .ksy file under dir to paths.
walk :: proc(dir: string, paths: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fmt.eprintfln("ksy_corpus: cannot read %s: %v", dir, err)
		os.exit(2)
	}
	for e in entries {
		path, _ := filepath.join({dir, e.name}, context.allocator)
		if e.type == .Directory {
			if !strings.has_prefix(e.name, ".") do walk(path, paths)
		} else if strings.has_suffix(e.name, ".ksy") {
			append(paths, path)
		}
	}
}

// path relative to root, with / as the separator.
relative :: proc(root, path: string) -> string {
	rel, err := filepath.rel(root, path, context.allocator)
	if err != nil do return path
	s, _ := strings.replace_all(rel, "\\", "/", context.allocator)
	return s
}

// s with its tabs and newlines made spaces, to keep the output one line a
// file.
one_line :: proc(s: string) -> string {
	b := strings.builder_make(context.allocator)
	for c in transmute([]byte)s {
		io.write_byte(strings.to_writer(&b), c == '\t' || c == '\n' ? ' ' : c)
	}
	return strings.to_string(b)
}
