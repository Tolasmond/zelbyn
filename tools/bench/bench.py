#!/usr/bin/env python3
"""Measures zelbyn cold, one fresh process per measurement.

    python3 tools/bench/bench.py [--runs N] [--schema S] [--spans] [--cpp BIN] [file ...]

Run from the repository root; needs Odin. Builds zelbyn and the one-shot
program in tools/bench with -o:speed, then runs each of these RUNS times
(default 200) per file, each time in a new process, interleaving files and
programs:

- the one-shot program, which compiles the schema, reads the file, decodes
  it and writes its JSON dump to memory, timing each phase, and counts the
  page faults taken during the decode;
- the CLI, `zelbyn <schema> <file> --dump json`, with its output discarded,
  timed from spawn to exit (with --spans, `--offsets`, the text dump with
  each value's offset, instead);
- the one-shot program with --start-only, which exits at once: the fixed
  cost of starting a process;
- with --cpp, the Kaitai Struct C++ reference built by cpp/build.py, which
  reads the file and decodes it with the official runtime.

With --spans the one-shot program decodes with spans. Prints the median
of every figure. The files default to the samples in
data/, and the schema to formats/gif.ksy; the C++ reference must have been
built from the same schema. A program that fails stops the run.
"""

import argparse
import glob
import os
import statistics
import subprocess
import sys
import tempfile
import time

EXE = '.exe' if os.name == 'nt' else ''


def run(cmd, capture):
    """Runs cmd; returns its wall time in µs and its name=value output."""
    start = time.perf_counter_ns()
    r = subprocess.run(cmd, stdout=subprocess.PIPE if capture else subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    wall = (time.perf_counter_ns() - start) / 1000
    if r.returncode != 0:
        sys.exit('%s failed (exit %d): %s' % (' '.join(cmd), r.returncode, r.stderr.strip()))
    fields = {}
    if capture:
        for pair in r.stdout.split():
            name, value = pair.split('=')
            fields[name] = float(value)
    return wall, fields


def median(rows, name):
    return statistics.median(row[name] for row in rows)


def main():
    p = argparse.ArgumentParser(description='Measures zelbyn cold, one fresh process per measurement.')
    p.add_argument('files', nargs='*')
    p.add_argument('--runs', type=int, default=200)
    p.add_argument('--schema', default='formats/gif.ksy')
    p.add_argument('--spans', action='store_true', help='decode with spans; the CLI writes the text dump with --offsets')
    p.add_argument('--cpp', help='the Kaitai Struct C++ reference, from cpp/build.py')
    args = p.parse_args()
    files = args.files or sorted(f for f in glob.glob('data/*') if f.lower().endswith('.gif'))

    with tempfile.TemporaryDirectory() as tmp:
        cli, oneshot = os.path.join(tmp, 'zelbyn' + EXE), os.path.join(tmp, 'bench_oneshot' + EXE)
        subprocess.run(['odin', 'build', '.', '-o:speed', '-out:' + cli], check=True)
        subprocess.run(['odin', 'build', 'tools/bench', '-o:speed', '-out:' + oneshot], check=True)

        results = {f: {'odin': [], 'cli': [], 'start': [], 'cpp': []} for f in files}
        for _ in range(args.runs):
            for f in files:
                r = results[f]
                _, fields = run([oneshot, args.schema, f] + (['--spans'] if args.spans else []), True)
                r['odin'].append(fields)
                r['cli'].append({'wall': run([cli, args.schema, f] + (['--offsets'] if args.spans else ['--dump', 'json']), False)[0]})
                r['start'].append({'wall': run([oneshot, '--start-only'], False)[0]})
                if args.cpp:
                    wall, fields = run([args.cpp, f], True)
                    fields['wall'] = wall
                    r['cpp'].append(fields)

    print('schema %s%s, %d runs per file, medians; times in µs' % (args.schema, ', with spans' if args.spans else '', args.runs))
    head = '%-14s %8s %8s %7s %8s %7s %8s %8s %9s' % ('file', 'input KB', 'tree KB', 'faults', 'compile', 'read', 'decode', 'json', 'CLI+offs' if args.spans else 'CLI+json')
    if args.cpp:
        head += ' | %8s %7s %6s %9s' % ('C++ dec', 'faults', 'ratio', 'C++ proc')
    print(head)
    for f in files:
        r = results[f]
        o = r['odin']
        line = '%-14s %8.1f %8.1f %7.0f %8.0f %7.0f %8.0f %8.0f %9.0f' % (
            os.path.basename(f), median(o, 'input_bytes') / 1024, median(o, 'tree_bytes') / 1024, median(o, 'faults'),
            median(o, 'compile_us'), median(o, 'read_us'), median(o, 'decode_us'), median(o, 'json_us'), median(r['cli'], 'wall'))
        if args.cpp:
            c = r['cpp']
            line += ' | %8.0f %7.0f %5.2fx %9.0f' % (median(c, 'decode_us'), median(c, 'faults'), median(o, 'decode_us') / median(c, 'decode_us'), median(c, 'wall'))
        print(line)
    print('process start (bench_oneshot --start-only): %.0f µs' % statistics.median(x['wall'] for f in files for x in results[f]['start']))


if __name__ == '__main__':
    main()
