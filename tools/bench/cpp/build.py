#!/usr/bin/env python3
"""Builds the Kaitai Struct C++ reference for tools/bench/bench.py.

    python3 tools/bench/cpp/build.py <runtime_dir> --schema <schema.ksy>

Run from the repository root, after `npm ci --prefix tools/kaitai_compare`.
runtime_dir is a clone of kaitai_struct_cpp_stl_runtime at tag 0.11, kept
outside this repository. The schema is converted to JSON with PyYAML, the
official compiler pinned in tools/kaitai_compare/package.json generates its
C++ parser, and that parser, the runtime and oneshot.cpp are compiled with
$CXX (default g++) at -O2. On Linux, libstdc++ is linked statically, so
that starting the process does not load it. Strings are kept as bytes
(KS_STR_ENCODING_NONE), as zelbyn keeps them. Everything goes into
tools/bench/cpp/build/, which is not committed; prints the binary's path.
"""

import argparse
import json
import os
import subprocess
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'build')
NODE_MODULES = os.path.join(HERE, '..', '..', 'kaitai_compare', 'node_modules')
RUNTIME_TAG = '0.11'


def main():
    p = argparse.ArgumentParser(description='Builds the Kaitai Struct C++ reference for bench.py.')
    p.add_argument('runtime_dir', help='a clone of kaitai_struct_cpp_stl_runtime at tag ' + RUNTIME_TAG)
    p.add_argument('--schema', required=True)
    args = p.parse_args()

    if not os.path.isdir(NODE_MODULES):
        sys.exit('run `npm ci --prefix tools/kaitai_compare` first')
    stream = os.path.join(args.runtime_dir, 'kaitai', 'kaitaistream.cpp')
    if not os.path.isfile(stream):
        sys.exit('%s is not a clone of kaitai_struct_cpp_stl_runtime (no kaitai/kaitaistream.cpp)' % args.runtime_dir)
    tag = subprocess.run(['git', '-C', args.runtime_dir, 'describe', '--tags'], capture_output=True, text=True).stdout.strip()
    if tag != RUNTIME_TAG:
        print('warning: %s is at %r, not tag %s' % (args.runtime_dir, tag or 'unknown', RUNTIME_TAG), file=sys.stderr)

    with open(args.schema) as f:
        ksy = yaml.safe_load(f)
    root = ksy['meta']['id']

    os.makedirs(OUT, exist_ok=True)
    schema_json = os.path.join(OUT, root + '.json')
    with open(schema_json, 'w') as f:
        json.dump(ksy, f)
    subprocess.run(['node', os.path.join(HERE, 'generate.js'), schema_json, OUT], check=True)

    exe = os.path.join(OUT, 'oneshot_cpp' + ('.exe' if os.name == 'nt' else ''))
    cmd = [os.environ.get('CXX', 'g++'), '-std=c++11', '-O2', '-DKS_STR_ENCODING_NONE',
           '-DKS_HEADER="%s.h"' % root, '-DKS_ROOT=%s_t' % root,
           '-I', args.runtime_dir, '-I', OUT,
           os.path.join(OUT, root + '.cpp'), stream, os.path.join(HERE, 'oneshot.cpp'), '-o', exe]
    if sys.platform.startswith('linux'):
        cmd[1:1] = ['-static-libstdc++', '-static-libgcc']
    subprocess.run(cmd, check=True)
    print(exe)


if __name__ == '__main__':
    main()
