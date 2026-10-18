// Prints the node tree that gnrcrdr's YAML parser builds for each file named
// on the command line, in the event form compare.py also builds from
// libyaml. Not part of gnrcrdr's build: compare.py builds and runs it.
package yaml_corpus

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import yml "../../gnrcrdr/yaml"

main :: proc() {
	out: bufio.Writer
	bufio.writer_init(&out, os.to_stream(os.stdout))
	defer bufio.writer_destroy(&out)
	w := bufio.writer_to_writer(&out)

	for path in os.args[1:] {
		fmt.wprintfln(w, "== %s", path)

		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.wprintfln(w, "READ-FAILED %v", err)
			continue
		}
		defer delete(data)

		doc: yml.Document
		defer yml.destroy_document(&doc)
		perr := yml.parse(string(data), &doc)
		defer yml.destroy_error(&perr)

		if perr.kind != .None {
			fmt.wprintfln(w, "REJECT %v %v:%v %s", perr.kind, perr.line, perr.column, perr.message)
		} else if doc.root != nil {
			write_node(w, doc.root)
		}
	}
	bufio.writer_flush(&out)
}

STYLE := [yml.Style]string {
	.Plain         = "plain",
	.Single_Quoted = "single",
	.Double_Quoted = "double",
	.Literal       = "literal",
	.Folded        = "folded",
}

write_node :: proc(w: io.Writer, n: ^yml.Node) {
	switch n.kind {
	case .Scalar:
		fmt.wprintf(w, "SCALAR %v:%v %s \"", n.line, n.column, STYLE[n.style])
		for c in transmute([]byte)n.text {
			if c >= 0x20 && c < 0x7f && c != '\\' && c != '"' {
				io.write_byte(w, c)
			} else {
				fmt.wprintf(w, "\\x%02x", c)
			}
		}
		io.write_string(w, "\"\n")
	case .Map:
		fmt.wprintfln(w, "MAP %v:%v", n.line, n.column)
		for e in n.entries {
			write_node(w, e.key)
			write_node(w, e.value)
		}
		io.write_string(w, "END\n")
	case .Seq:
		fmt.wprintfln(w, "SEQ %v:%v", n.line, n.column)
		for item in n.items do write_node(w, item)
		io.write_string(w, "END\n")
	}
}
