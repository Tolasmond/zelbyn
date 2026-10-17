package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// With -define:GOLDEN_RECORD=true the golden tests rewrite tests/golden/
// from the current decoder instead of comparing against it. Review the
// resulting diff before committing it.
GOLDEN_RECORD :: #config(GOLDEN_RECORD, false)

GOLDEN_DIR :: "tests/golden"

// Bytes of context shown either side of the first difference.
GOLDEN_CONTEXT :: 60

// Dumps a sample as text and as JSON and compares each, byte for byte, with
// tests/golden/<file name>.tree and .json.
@(private = "file")
check_golden :: proc(t: ^testing.T, s: Sample) {
	testing.set_fail_timeout(t, 10 * time.Second)

	for as_json in ([?]bool{false, true}) {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		if !dump_sample(t, s.path, as_json, &b) do continue

		golden_path := fmt.aprintf("%s/%s.%s", GOLDEN_DIR, filepath.base(s.path), as_json ? "json" : "tree")
		defer delete(golden_path)

		compare_golden(t, golden_path, strings.to_string(b))
	}
}

@(private = "file")
compare_golden :: proc(t: ^testing.T, golden_path: string, got: string) {
	when GOLDEN_RECORD {
		err := os.write_entire_file(golden_path, got)
		testing.expectf(t, err == nil, "%s: write failed: %v", golden_path, err)
	} else {
		data, err := os.read_entire_file(golden_path, context.allocator)
		defer delete(data)
		if !testing.expectf(t, err == nil, "%s: read failed: %v (record with -define:GOLDEN_RECORD=true)", golden_path, err) do return

		want := string(data)
		if got == want do return

		// first differing byte, and the line it is on
		i := 0
		for i < min(len(got), len(want)) && got[i] == want[i] do i += 1
		line := strings.count(got[:i], "\n") + 1

		testing.expectf(
			t,
			false,
			"%s: dump differs at byte %v (line %v); got %v bytes, want %v\n  got:  %q\n  want: %q",
			golden_path,
			i,
			line,
			len(got),
			len(want),
			excerpt(got, i),
			excerpt(want, i))
	}
}

@(private = "file")
excerpt :: proc(s: string, i: int) -> string {
	return s[max(i - GOLDEN_CONTEXT, 0):min(i + GOLDEN_CONTEXT, len(s))]
}

@(test)
golden_855 :: proc(t: ^testing.T) {
	check_golden(t, SAMPLE_855)
}

@(test)
golden_89aillus :: proc(t: ^testing.T) {
	check_golden(t, SAMPLE_89AILLUS)
}

@(test)
golden_bob_89a :: proc(t: ^testing.T) {
	check_golden(t, SAMPLE_BOB_89A)
}

@(test)
golden_cg89a :: proc(t: ^testing.T) {
	check_golden(t, SAMPLE_CG89A)
}

@(test)
golden_stigr9 :: proc(t: ^testing.T) {
	check_golden(t, SAMPLE_STIGR9)
}

@(test)
golden_texttst :: proc(t: ^testing.T) {
	check_golden(t, SAMPLE_TEXTTST)
}
