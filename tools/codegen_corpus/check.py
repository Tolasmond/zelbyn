#!/usr/bin/env python3
"""Generates the Odin code of every .ksy file in a clone of
kaitai_struct_formats that zelbyn compiles, builds each package, and with
--samples, decodes the samples of a clone of kaitai_struct_samples with it,
comparing each decode with zelbyn's own.

    python3 tools/codegen_corpus/check.py [--samples DIR] [--jobs N] [--keep DIR] <formats dir>

Run from the repository root. Needs Odin. Each package is generated with
zelbyn gen, with the directory as the import path, and built, with
-vet -strict-style, with a program that decodes the file named on its
command line and writes the text dump, or the error, as zelbyn does. A
schema that zelbyn does not compile is skipped (tools/ksy_corpus/check.py
records those); one that it compiles but cannot generate code for, or
whose code does not build, is a failure.

With --samples, the samples of each format are those that
tools/ksy_corpus/check.py decodes: the files in the directory named as the
format's .ksy file that have a .license file beside them, other than .txt
and .json files. Each is decoded with zelbyn and with the generated code,
and the two must agree in exit code, output and error message. The
generated code has no limits on nesting, memory or steps (doc/usage.md,
"Generating code"), which no sample reaches, so any difference is a bug.

Exits 1 if any schema fails or any sample differs. --keep DIR keeps the
packages and programs in DIR rather than a temporary directory; --jobs N
builds and decodes N at a time (default: the number of CPUs).
"""

import argparse
import concurrent.futures
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))

# The program each package is built with: it decodes the file named on its
# command line, and writes the text dump, or the error, as zelbyn's command
# line (zelbyn/cli/cli.odin) writes them.
MAIN = '''// Decodes the file named on the command line with the generated package
// beside it, and writes the text dump, or the error, as zelbyn does.
package main

import "core:bufio"
import "core:fmt"
import "core:os"
import dat "zelbyn:data"
import pkg "../pkg"

main :: proc() {
	data, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {
		fmt.eprintfln("error: cannot read %s: %v", os.args[1], read_err)
		os.exit(1)
	}
	root, err := pkg.read(data)
	if err.kind != .None {
		fmt.eprintf("error: %v at 0x%08X in %s", err.kind, err.offset, err.path)
		write_check_values(err)
		fmt.eprintln()
		os.exit(1)
	}
	out: bufio.Writer
	bufio.writer_init(&out, os.to_stream(os.stdout))
	write_err := pkg.write_text(bufio.writer_to_writer(&out), root)
	if write_err == .None do write_err = bufio.writer_flush(&out)
	if write_err != .None {
		fmt.eprintfln("error: writing output: %v", write_err)
		os.exit(1)
	}
}

write_check_values :: proc(err: dat.Parse_Error) {
	if err.value != "" do fmt.eprintf(": read %s", err.value)
	if err.expected == "" do return
	fmt.eprint(err.value != "" ? ", expected " : ": expected ")
	#partial switch err.kind {
	case .Less_Than_Min:
		fmt.eprint("at least ")
	case .Greater_Than_Max:
		fmt.eprint("at most ")
	case .Not_Any_Of, .Not_In_Enum:
		fmt.eprint("one of ")
	}
	fmt.eprint(err.expected)
}
'''


def ksy_files(root):
    """The .ksy files under root, relative to it, sorted."""
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith('.'))
        out += [os.path.relpath(os.path.join(d, f), root) for f in files if f.endswith('.ksy')]
    return sorted(p.replace(os.sep, '/') for p in out)


def samples_of(samples, path):
    """The samples of the format path, as tools/ksy_corpus/check.py finds
    them."""
    sample_dir = os.path.join(samples, path[:-len('.ksy')])
    if not os.path.isdir(sample_dir):
        return []
    return sorted(os.path.join(sample_dir, f) for f in os.listdir(sample_dir)
                  if os.path.isfile(os.path.join(sample_dir, f + '.license')) and not f.endswith(('.txt', '.json')))


def generate_and_build(zelbyn, formats, work, index, path):
    """Generates and builds the package of the schema path. Returns
    (status, message, program): status is 'built', 'skipped' (zelbyn does
    not compile it) or 'failed'."""
    d = os.path.join(work, '%03d' % index)
    pkg = os.path.join(d, 'pkg')
    main = os.path.join(d, 'main')
    os.makedirs(main, exist_ok=True)
    r = subprocess.run([zelbyn, 'gen', os.path.join(formats, path), '--out', pkg, '--import-path', formats],
                       capture_output=True, text=True)
    if r.returncode != 0:
        message = (r.stdout + r.stderr).strip()
        if 'cannot generate code' in message:
            return 'failed', message, None
        return 'skipped', message, None
    with open(os.path.join(main, 'main.odin'), 'w') as f:
        f.write(MAIN)
    program = os.path.join(d, 'decode' + ('.exe' if os.name == 'nt' else ''))
    r = subprocess.run(['odin', 'build', main, '-collection:zelbyn=' + os.path.join(REPO, 'zelbyn'), '-out:' + program,
                        '-vet', '-strict-style'], capture_output=True, text=True)
    if r.returncode != 0:
        lines = (r.stdout + r.stderr).strip().splitlines()
        return 'failed', 'odin build failed:\n' + '\n'.join(lines[:30]), None
    return 'built', '', program


def decode(cmd):
    r = subprocess.run(cmd, capture_output=True)
    return r.returncode, r.stdout, r.stderr


def compare(zelbyn, formats, path, program, sample):
    """Whether zelbyn and program decode sample alike, and how they differ."""
    want = decode([zelbyn, os.path.join(formats, path), sample, '--import-path', formats])
    got = decode([program, sample])
    if want == got:
        return True, ''
    lines = []
    if want[0] != got[0]:
        lines.append('exit code %d, generated %d' % (want[0], got[0]))
    for name, a, b in (('stdout', want[1], got[1]), ('stderr', want[2], got[2])):
        if a == b:
            continue
        al, bl = a.decode(errors='replace').splitlines(), b.decode(errors='replace').splitlines()
        for i in range(max(len(al), len(bl))):
            x = al[i] if i < len(al) else '<none>'
            y = bl[i] if i < len(bl) else '<none>'
            if x != y:
                lines.append('%s line %d:\n  zelbyn:    %s\n  generated: %s' % (name, i + 1, x, y))
                break
    return False, '\n'.join(lines)


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument('--samples')
    p.add_argument('--jobs', type=int, default=os.cpu_count() or 1)
    p.add_argument('--keep')
    p.add_argument('formats')
    args = p.parse_args()
    formats = os.path.abspath(args.formats)

    with tempfile.TemporaryDirectory() as tmp:
        work = os.path.abspath(args.keep) if args.keep else tmp
        os.makedirs(work, exist_ok=True)
        zelbyn = os.path.join(work, 'zelbyn' + ('.exe' if os.name == 'nt' else ''))
        subprocess.run(['odin', 'build', REPO, '-out:' + zelbyn], check=True)

        paths = ksy_files(formats)
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
            results = list(pool.map(lambda ip: generate_and_build(zelbyn, formats, work, ip[0], ip[1]), enumerate(paths)))

        built = {}
        failed = 0
        skipped = 0
        for path, (status, message, program) in zip(paths, results):
            if status == 'built':
                built[path] = program
            elif status == 'skipped':
                skipped += 1
            else:
                failed += 1
                print('FAILED: %s\n%s' % (path, message))
        print('%d of %d files generate and build (%d not compiled by zelbyn, %d failed)' % (
            len(built), len(paths), skipped, failed))

        differ = 0
        if args.samples:
            jobs = [(path, program, s) for path, program in sorted(built.items()) for s in samples_of(args.samples, path)]
            with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
                outcomes = list(pool.map(lambda j: compare(zelbyn, formats, *j), jobs))
            formats_seen = sorted(set(path for path, _, _ in jobs))
            for (path, _, sample), (same, message) in zip(jobs, outcomes):
                if not same:
                    differ += 1
                    print('DIFFERS: %s %s\n%s' % (path, os.path.relpath(sample, args.samples), message))
            print('%d of %d samples of %d formats decode alike' % (len(jobs) - differ, len(jobs), len(formats_seen)))

    sys.exit(1 if failed or differ else 0)


if __name__ == '__main__':
    main()
