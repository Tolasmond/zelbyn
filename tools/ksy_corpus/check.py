#!/usr/bin/env python3
"""Compiles every .ksy file in a clone of kaitai_struct_formats with
zelbyn's compiler, and compares the result with the one recorded in
expected.txt, so that the supported subset is measured and changes to it
are seen.

    python3 tools/ksy_corpus/check.py [--record] [--samples DIR] <formats dir>

Run from the repository root. Needs Odin. Each file either compiles or
fails with its first error, as main.odin prints it. Exits 1 if any file
differs from the record: one that no longer compiles, one that now does,
or one whose first error changed. After a change to the compiler that is
meant to change them, check the differences and run again with --record,
which rewrites expected.txt. The record names the commit of
kaitai_struct_formats it was made at; a clone at another commit is an
error, unless --record is given.

With --samples, a clone of kaitai_struct_samples, which keeps the samples
of each format in a directory named as the format's .ksy file, every
format that compiles and has samples is also decoded with
tools/kaitai_compare/compare.py, which compares the values and offsets of
each sample with the official runtime's. Its samples are the files there
with a .license file beside them (REUSE's for a binary file), other than
.txt and .json files, which describe them. That needs what compare.py
needs; it exits 1 if any format differs.
"""

import argparse
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EXPECTED = os.path.join(HERE, 'expected.txt')
COMPARE = os.path.join(HERE, '..', 'kaitai_compare', 'compare.py')


def commit(path):
    """The commit a git clone is at, or None."""
    r = subprocess.run(['git', '-C', path, 'rev-parse', 'HEAD'], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def results(lines):
    """The result of each file, by its path: '' when it compiles, else its
    first error."""
    out = {}
    for line in lines:
        fields = line.split('\t')
        out[fields[1]] = '\t'.join(fields[2:]) if fields[0] == 'ERR' else ''
    return out


def check_samples(formats, samples, compiled):
    """Compares the decode of the samples of every format in compiled with
    the official runtime's. Returns the number of formats that differ."""
    failed = 0
    for path in sorted(compiled):
        sample_dir = os.path.join(samples, path[:-len('.ksy')])
        if not os.path.isdir(sample_dir):
            continue
        files = sorted(os.path.join(sample_dir, f) for f in os.listdir(sample_dir)
                       if os.path.isfile(os.path.join(sample_dir, f + '.license')) and not f.endswith(('.txt', '.json')))
        if not files:
            continue
        for mode in ([], ['--offsets']):
            r = subprocess.run([sys.executable, COMPARE, '--import-path', formats] + mode + [os.path.join(formats, path)] + files,
                               capture_output=True, text=True)
            summary = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr.strip()
            print('samples %s%s: %s' % (path, ' (offsets)' if mode else '', summary))
            if r.returncode != 0:
                failed += 1
                print(r.stdout + r.stderr, end='')
    return failed


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument('--record', action='store_true')
    p.add_argument('--samples')
    p.add_argument('formats')
    args = p.parse_args()

    at = commit(args.formats)
    with tempfile.TemporaryDirectory() as tmp:
        tool = os.path.join(tmp, 'ksy_corpus')
        subprocess.run(['odin', 'build', HERE, '-out:' + tool], check=True)
        lines = subprocess.run([tool, args.formats], check=True, capture_output=True, text=True).stdout.splitlines()
    now = results(lines)
    compiled = [path for path, err in now.items() if not err]
    print('%d of %d files compile' % (len(compiled), len(now)))

    if args.record:
        with open(EXPECTED, 'w') as f:
            f.write('# kaitai_struct_formats %s: %d of %d files compile\n' % (at or 'unknown', len(compiled), len(now)))
            f.writelines(line + '\n' for line in lines)
        print('recorded in %s' % os.path.relpath(EXPECTED))
    else:
        with open(EXPECTED) as f:
            header, *recorded = f.read().splitlines()
        recorded_at = header.split()[2].rstrip(':')
        if at != recorded_at:
            sys.exit('expected.txt was recorded at kaitai_struct_formats %s, and %s is at %s' % (recorded_at, args.formats, at))
        before = results(recorded)
        lost = [p for p in sorted(before) if p in now and not before[p] and now[p]]
        gained = [p for p in sorted(before) if p in now and before[p] and not now[p]]
        changed = [p for p in sorted(before) if p in now and before[p] and now[p] and before[p] != now[p]]
        added = sorted(set(now) - set(before))
        removed = sorted(set(before) - set(now))
        for path in lost:
            print('NO LONGER COMPILES: %s\n  %s' % (path, now[path]))
        for path in gained:
            print('now compiles: %s (was %s)' % (path, before[path]))
        for path in changed:
            print('first error changed: %s\n  was: %s\n  now: %s' % (path, before[path], now[path]))
        for path in added + removed:
            print('%s: %s' % ('not recorded' if path in now else 'missing', path))
        differ = len(lost) + len(gained) + len(changed) + len(added) + len(removed)
        print('%d differ from the record: %d no longer compile, %d now compile, %d changed first error' % (
            differ, len(lost), len(gained), len(changed)))
        if differ:
            print('if that is intended, run again with --record')

    failed = check_samples(args.formats, args.samples, compiled) if args.samples else 0
    sys.exit(1 if failed or (not args.record and differ) else 0)


if __name__ == '__main__':
    main()
