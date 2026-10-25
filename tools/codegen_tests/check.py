#!/usr/bin/env python3
"""Decodes every input that the tests decode again, with the code generated
from its schema, and compares the results with the decoder's.

    python3 tools/codegen_tests/check.py [--keep DIR]

Run from the repository root. Needs Odin. It runs the tests with
-define:ZELBYN_CODEGEN_RECORD=<dir>, which makes tests/helpers.odin's
decode_bytes and decode_file record each decode in <dir>: the package that
zelbyn's generator writes for the plan, once for each package, and with
it the input, the arguments of the schema's top-level params, and the
decoder's result, its text dump or its error. It then builds one program,
with -vet -strict-style, that imports every package and decodes the input
of each case with the package of its plan, writing the result as the
recording does, and runs every case. Each must give the decoder's result:
the same dump, or the same error at the same offset and path, with the same
values shown.

Decodes that reach a limit of the decoder, which generated code does not
have (doc/usage.md, "Generating code"), are not recorded. Nor is a decode
whose plan the generator cannot write code for, which tests/helpers.odin
lists in <dir>/not_generated.txt, and this prints and fails on: every plan
should have code, those that the tests build by hand too.

Exits 1 if the tests fail, a plan has no code, the program does not build,
or a case differs.
--keep DIR records in DIR rather than a temporary directory.
"""

import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))

# The program: it decodes the file of case n, the second and third
# arguments, with the package of its plan, and writes the result as
# tests/helpers.odin's decode_result writes it.
MAIN = '''// Decodes the input of a case recorded by tests/helpers.odin with the
// generated package of its plan, and writes the result as it does.
package main

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import dat "zelbyn:data"
IMPORTS

main :: proc() {
	n, _ := strconv.parse_int(os.args[1])
	data, read_err := os.read_entire_file(os.args[2], context.allocator)
	if read_err != nil {
		fmt.eprintfln("cannot read %s: %v", os.args[2], read_err)
		os.exit(2)
	}
	out: bufio.Writer
	bufio.writer_init(&out, os.to_stream(os.stdout))
	defer bufio.writer_flush(&out)
	w := bufio.writer_to_writer(&out)
	write_err: io.Error
	err: dat.Parse_Error
	switch n {
CASES	case:
		fmt.eprintfln("no case %d", n)
		os.exit(2)
	}
	if write_err != .None do os.exit(2)
	if err.kind == .None do return
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

# The arm of the switch of case n, of the package called name.
CASE = '''	case %d:
		root: ^%s.%s
		root, err = %s.read(data, %s.Args%s)
		if err.kind == .None do write_err = %s.write_text(w, root)
'''


def root_type(source):
    """The name of the top-level type that the package source decodes, as its
    read gives it."""
    for line in source.splitlines():
        if line.startswith('read :: proc(') and '-> (root: ^' in line:
            return line.split('-> (root: ^')[1].split(',')[0]
    raise ValueError('no read in the package')


def main():
    p = argparse.ArgumentParser(usage=__doc__)
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
        skipped = []
        if os.path.isfile(not_generated):
            with open(not_generated) as f:
                skipped = sorted(set(f.read().splitlines()))
            print('%d plans have no code:' % len(skipped))
            for line in skipped:
                print('  ' + line)

        packages = sorted(x for x in os.listdir(record) if os.path.isdir(os.path.join(record, x, 'cases')))
        imports, arms, cases = [], [], []
        for name in packages:
            with open(os.path.join(record, name, name + '.odin')) as f:
                root = root_type(f.read())
            imports.append('import %s "../%s"' % (name, name))
            case_dir = os.path.join(record, name, 'cases')
            for n in sorted(int(x[:-len('.bin')]) for x in os.listdir(case_dir) if x.endswith('.bin')):
                with open(os.path.join(case_dir, '%d.args' % n)) as f:
                    literal = f.read()
                arms.append(CASE % (n, name, root, name, name, literal, name))
                cases.append((name, n))
        main_dir = os.path.join(record, 'main')
        os.makedirs(main_dir, exist_ok=True)
        with open(os.path.join(main_dir, 'main.odin'), 'w') as f:
            f.write(MAIN.replace('IMPORTS', '\n'.join(imports)).replace('CASES', ''.join(arms)))
        program = os.path.join(record, 'decode' + ('.exe' if os.name == 'nt' else ''))
        r = subprocess.run(['odin', 'build', main_dir, '-collection:zelbyn=' + os.path.join(REPO, 'zelbyn'), '-out:' + program,
                            '-vet', '-strict-style'], capture_output=True, text=True)
        if r.returncode != 0:
            print('\n'.join((r.stdout + r.stderr).strip().splitlines()[:60]))
            sys.exit('the generated packages do not build')

        differ = 0
        for name, n in cases:
            case = os.path.join(record, name, 'cases', '%d' % n)
            r = subprocess.run([program, str(n), case + '.bin'], capture_output=True)
            with open(case + '.want', 'rb') as f:
                want = f.read()
            if r.returncode == 0 and r.stdout == want:
                continue
            differ += 1
            got, wanted = r.stdout.decode(errors='replace').splitlines(), want.decode(errors='replace').splitlines()
            message = 'exit code %d: %s' % (r.returncode, r.stderr.decode(errors='replace').strip())
            for i in range(max(len(got), len(wanted))):
                x = wanted[i] if i < len(wanted) else '<none>'
                y = got[i] if i < len(got) else '<none>'
                if x != y:
                    message = 'line %d:\n  decoder:   %s\n  generated: %s' % (i + 1, x, y)
                    break
            print('DIFFERS: %s case %d\n%s' % (name, n, message))
        print('%d packages; %d of %d decodes agree' % (len(packages), len(cases) - differ, len(cases)))
    sys.exit(1 if differ or skipped else 0)


if __name__ == '__main__':
    main()
