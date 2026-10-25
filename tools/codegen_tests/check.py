#!/usr/bin/env python3
"""Decodes every input that the tests decode again, with the code generated
from its schema, and compares the results with the decoder's.

    python3 tools/codegen_tests/check.py [--jobs N] [--keep DIR]

Run from the repository root. Needs Odin. It runs the tests with
-define:ZELBYN_CODEGEN_RECORD=<dir>, which makes tests/helpers.odin's
decode_bytes and decode_file record each decode in <dir>: the package that
zelbyn's generator writes for the plan, once for each package, and with
it the input, the arguments of the schema's top-level params, and the
decoder's result, its text dump or its error. It then builds each package,
with -vet -strict-style, with a program that decodes the input of a case
and writes its result as the recording does, and runs every case. Each
must give the decoder's result: the same dump, or the same error at the
same offset and path, with the same values shown.

Decodes that reach a limit of the decoder, which generated code does not
have (doc/usage.md, "Generating code"), are not recorded; nor are those of
plans that a test builds by hand, without the types of a schema, which the
generator cannot write code for; tests/helpers.odin lists the latter in
<dir>/not_generated.txt, which this prints.

Exits 1 if the tests fail, a package does not build, or a case differs.
--keep DIR records in DIR rather than a temporary directory; --jobs N builds
and runs N at a time (default: the number of CPUs).
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))

# The program of each package: case n's arguments, and the result of the
# decode of the file named after n, as tests/helpers.odin's decode_result
# writes it.
MAIN = '''// Decodes the input of a case recorded by tests/helpers.odin with the
// generated package beside it, and writes the result as it does.
package main

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import pkg "../pkg"

main :: proc() {
	n, _ := strconv.parse_int(os.args[1])
	data, read_err := os.read_entire_file(os.args[2], context.allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", os.args[2], read_err)
		os.exit(2)
	}
	args: pkg.Args
	switch n {
CASES	}
	out: bufio.Writer
	bufio.writer_init(&out, os.to_stream(os.stdout))
	defer bufio.writer_flush(&out)
	w := bufio.writer_to_writer(&out)
	root, err := pkg.read(data, args)
	if err.kind == .None {
		if e := pkg.write_text(w, root); e != .None do os.exit(2)
		return
	}
	fmt.wprintf(w, "error: %v at 0x%08X in %s", err.kind, err.offset, err.path)
	if err.value != "" do fmt.wprintf(w, ": read %s", err.value)
	if err.expected != "" {
		io.write_string(w, err.value != "" ? ", expected " : ": expected ")
		#partial switch err.kind {
		case .Less_Than_Min:
			io.write_string(w, "at least ")
		case .Greater_Than_Max:
			io.write_string(w, "at most ")
		case .Not_Any_Of, .Not_In_Enum:
			io.write_string(w, "one of ")
		}
		io.write_string(w, err.expected)
	}
	io.write_byte(w, '\\n')
}
'''


def cases_of(d):
    """The numbers of the cases recorded in package directory d."""
    names = os.listdir(os.path.join(d, 'cases'))
    return sorted(int(n[:-len('.bin')]) for n in names if n.endswith('.bin'))


def build(d):
    """Builds the program of package directory d. Returns (ok, message)."""
    arms = ''
    for n in cases_of(d):
        with open(os.path.join(d, 'cases', '%d.args' % n)) as f:
            arms += '\tcase %d:\n\t\targs = %s\n' % (n, f.read())
    main = os.path.join(d, 'main')
    os.makedirs(main, exist_ok=True)
    with open(os.path.join(main, 'main.odin'), 'w') as f:
        f.write(MAIN.replace('CASES', arms))
    program = os.path.join(d, 'decode' + ('.exe' if os.name == 'nt' else ''))
    r = subprocess.run(['odin', 'build', main, '-collection:zelbyn=' + os.path.join(REPO, 'zelbyn'), '-out:' + program,
                        '-vet', '-strict-style'], capture_output=True, text=True)
    if r.returncode != 0:
        lines = (r.stdout + r.stderr).strip().splitlines()
        return False, '\n'.join(lines[:30])
    return True, ''


def run_case(d, n):
    """Whether case n of package directory d gives the decoder's result, and
    how it differs."""
    program = os.path.join(d, 'decode' + ('.exe' if os.name == 'nt' else ''))
    r = subprocess.run([program, str(n), os.path.join(d, 'cases', '%d.bin' % n)], capture_output=True)
    with open(os.path.join(d, 'cases', '%d.want' % n), 'rb') as f:
        want = f.read()
    if r.returncode == 0 and r.stdout == want:
        return True, ''
    got, wanted = r.stdout.decode(errors='replace').splitlines(), want.decode(errors='replace').splitlines()
    for i in range(max(len(got), len(wanted))):
        x = wanted[i] if i < len(wanted) else '<none>'
        y = got[i] if i < len(got) else '<none>'
        if x != y:
            return False, 'line %d:\n  decoder:   %s\n  generated: %s' % (i + 1, x, y)
    return False, 'exit code %d: %s' % (r.returncode, r.stderr.decode(errors='replace').strip())


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument('--jobs', type=int, default=os.cpu_count() or 1)
    p.add_argument('--keep')
    args = p.parse_args()
    if not os.path.isfile('main.odin'):
        sys.exit('run from the repository root')

    with tempfile.TemporaryDirectory() as tmp:
        record = os.path.abspath(args.keep) if args.keep else os.path.join(tmp, 'record')
        os.makedirs(record, exist_ok=True)
        tests = os.path.join(tmp, 'tests' + ('.exe' if os.name == 'nt' else ''))
        r = subprocess.run(['odin', 'test', 'tests', '-out:' + tests, '-define:ODIN_TEST_LOG_LEVEL=warning',
                            '-define:ZELBYN_CODEGEN_RECORD=' + record.replace('\\', '/')])
        if r.returncode != 0:
            sys.exit('the tests failed while recording')

        not_generated = os.path.join(record, 'not_generated.txt')
        if os.path.isfile(not_generated):
            with open(not_generated) as f:
                skipped = sorted(set(f.read().splitlines()))
            print('%d plans that tests build by hand have no code:' % len(skipped))
            for line in skipped:
                print('  ' + line)

        dirs = sorted(os.path.join(record, x) for x in os.listdir(record) if os.path.isdir(os.path.join(record, x, 'pkg')))
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            built = list(pool.map(build, dirs))
        failed = 0
        for d, (ok, message) in zip(dirs, built):
            if not ok:
                failed += 1
                print('DOES NOT BUILD: %s\n%s' % (d, message))

        jobs = [(d, n) for d, (ok, _) in zip(dirs, built) if ok for n in cases_of(d)]
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            outcomes = list(pool.map(lambda j: run_case(*j), jobs))
        differ = 0
        for (d, n), (same, message) in zip(jobs, outcomes):
            if not same:
                differ += 1
                print('DIFFERS: %s case %d\n%s' % (d, n, message))
        print('%d packages, %d do not build; %d of %d decodes agree' % (len(dirs), failed, len(jobs) - differ, len(jobs)))
    sys.exit(1 if failed or differ else 0)


if __name__ == '__main__':
    main()
