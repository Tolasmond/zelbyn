#!/usr/bin/env python3
"""Runs the checks a change must pass, as doc/development.md lists them.

    python3 tools/check.py [--formats DIR] [--samples DIR] [--yaml-corpus] [--compare-tests]

Run from the repository root. Needs Odin, the version that ODIN_VERSION
names (another is warned of, not refused). Always run, in order:

  - odin check . -vet -strict-style, and with -debug
  - odin check tests -vet -strict-style -no-entry-point
  - the tests, built without and with -o:speed, and with -debug, which
    uses the most stack, with ODIN_TEST_FAIL_ON_BAD_MEMORY
  - odin check -vet -strict-style of tools/bench, tools/ksy_corpus and
    tools/yaml_corpus

and, only when asked, as each needs what the repository does not hold:

  --formats DIR    tools/ksy_corpus/check.py over DIR, a clone of
                   kaitai_struct_formats at the commit
                   tools/ksy_corpus/expected.txt records
  --samples DIR    with --formats, its --samples DIR: a clone of
                   kaitai_struct_samples at the commit doc/development.md
                   gives, and Node.js, PyYAML and npm ci --prefix
                   tools/kaitai_compare. It fails today, on the two samples
                   doc/development.md names, so this script does too.
  --yaml-corpus    with --formats, tools/yaml_corpus/compare.py over DIR;
                   needs PyYAML built with libyaml
  --compare-tests  tools/kaitai_compare/test_compare.py; needs Node.js,
                   PyYAML and npm ci --prefix tools/kaitai_compare

Every check runs, whatever the ones before it give, and a summary ends the
output. Exits 1 if any check that ran failed, optional ones included: a
check's failure is reported as one, not passed over.
"""

import argparse
import os
import subprocess
import sys
import tempfile

# The Odin release the checks are run with, here and in CI
# (.github/workflows/check.yml): dev-2026-10, commit 84bc3fc.
ODIN_VERSION = 'dev-2026-10'
ODIN_COMMIT = '84bc3fc'

TEST_DEFINES = ['-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true', '-define:ODIN_TEST_LOG_LEVEL=warning']


def run(name, cmd, results):
    """Runs cmd, showing its output, and records whether it passed."""
    print('== %s\n   %s' % (name, ' '.join(cmd)), flush=True)
    try:
        ok = subprocess.run(cmd).returncode == 0
    except FileNotFoundError as e:
        print('   %s' % e)
        ok = False
    print('   %s\n' % ('passed' if ok else 'FAILED'), flush=True)
    results.append((name, ok))


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument('--formats')
    p.add_argument('--samples')
    p.add_argument('--yaml-corpus', action='store_true')
    p.add_argument('--compare-tests', action='store_true')
    args = p.parse_args()
    if (args.samples or args.yaml_corpus) and not args.formats:
        sys.exit('--samples and --yaml-corpus need --formats')
    if not os.path.isfile('main.odin'):
        sys.exit('run from the repository root')

    try:
        version = subprocess.run(['odin', 'version'], capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        sys.exit('odin is not on PATH; install %s (commit %s)' % (ODIN_VERSION, ODIN_COMMIT))
    print(version)
    if ODIN_COMMIT not in version:
        print('warning: the checks are pinned to Odin %s (commit %s)\n' % (ODIN_VERSION, ODIN_COMMIT))

    results = []
    with tempfile.TemporaryDirectory() as tmp:
        tests = os.path.join(tmp, 'tests' + ('.exe' if os.name == 'nt' else ''))
        run('odin check .', ['odin', 'check', '.', '-vet', '-strict-style'], results)
        run('odin check . -debug', ['odin', 'check', '.', '-vet', '-strict-style', '-debug'], results)
        run('odin check tests', ['odin', 'check', 'tests', '-vet', '-strict-style', '-no-entry-point'], results)
        run('tests', ['odin', 'test', 'tests', '-out:' + tests] + TEST_DEFINES, results)
        run('tests -o:speed', ['odin', 'test', 'tests', '-o:speed', '-out:' + tests] + TEST_DEFINES, results)
        run('tests -debug', ['odin', 'test', 'tests', '-debug', '-out:' + tests] + TEST_DEFINES, results)
        for tool in ('tools/bench', 'tools/ksy_corpus', 'tools/yaml_corpus'):
            run('odin check ' + tool, ['odin', 'check', tool, '-vet', '-strict-style'], results)

    if args.formats:
        cmd = [sys.executable, 'tools/ksy_corpus/check.py']
        if args.samples:
            cmd += ['--samples', args.samples]
        run('ksy corpus' + (' and samples' if args.samples else ''), cmd + [args.formats], results)
    if args.yaml_corpus:
        run('yaml corpus', [sys.executable, 'tools/yaml_corpus/compare.py', args.formats], results)
    if args.compare_tests:
        run('kaitai_compare tests', [sys.executable, 'tools/kaitai_compare/test_compare.py'], results)

    print('== summary')
    for name, ok in results:
        print('   %-28s %s' % (name, 'passed' if ok else 'FAILED'))
    failed = sum(1 for _, ok in results if not ok)
    print('%d checks, %d failed' % (len(results), failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
