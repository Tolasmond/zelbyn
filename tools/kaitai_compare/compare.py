#!/usr/bin/env python3
"""Compares gnrcrdr's decode of files with the official Kaitai Struct
runtime's, value by value (decision record §8, step 6).

    python3 tools/kaitai_compare/compare.py <schema.ksy> <file>...

Run from the repository root, after `npm ci --prefix tools/kaitai_compare`.
Needs Odin, Node.js and PyYAML. The schema is compiled with the official
compiler to JavaScript and run with the JavaScript runtime (decode.js), and
with gnrcrdr's --dump json. Both are brought to one shape: every field an
array of its values, set instances objects, byte arrays hex. A field with
no values (not read because of if or switch-on, or an empty repeat) is left
out on both sides, as are value instances, which gnrcrdr does not dump.
Field names are compared as the generated code spells them. Exits 1 if any
file differs, or fails to decode on either side.
"""

import json
import os
import subprocess
import sys
import tempfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))


def camel(name):
    """A .ksy id as the JavaScript compiler names it: lower_camel_case."""
    first, *rest = name.split('_')
    return first + ''.join(p[:1].upper() + p[1:] for p in rest)


def ours(value):
    """gnrcrdr's JSON dump of a set instance in decode.js's shape."""
    if isinstance(value, dict):
        return {camel(k): [ours(x) for x in v] for k, v in value.items() if v}
    return value


def theirs(value):
    if isinstance(value, dict):
        return {k: [theirs(x) for x in v] for k, v in value.items() if v}
    return value


def first_difference(a, b, path):
    """The path of the first value that differs, and the two values; None
    when a and b are equal. Also counts the values compared."""
    if isinstance(a, dict) and isinstance(b, dict):
        for k in list(a) + [k for k in b if k not in a]:
            if k not in a or k not in b:
                return path + '.' + k, a.get(k, '(absent)'), b.get(k, '(absent)')
            for i in range(max(len(a[k]), len(b[k]))):
                p = '%s.%s[%d]' % (path, k, i)
                if i >= len(a[k]) or i >= len(b[k]):
                    return p, a[k][i] if i < len(a[k]) else '(absent)', b[k][i] if i < len(b[k]) else '(absent)'
                d = first_difference(a[k][i], b[k][i], p)
                if d:
                    return d
        return None
    first_difference.values += 1
    return None if a == b and type(a) is type(b) else (path, a, b)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    schema, files = sys.argv[1], sys.argv[2:]
    if not os.path.isdir(os.path.join(HERE, 'node_modules')):
        sys.exit('run npm ci --prefix tools/kaitai_compare first')

    with open(schema, 'rb') as f:
        ksy = yaml.safe_load(f)
    root_name = ksy['meta']['id']

    with tempfile.TemporaryDirectory() as tmp:
        schema_json = os.path.join(tmp, 'schema.json')
        with open(schema_json, 'w') as f:
            json.dump(ksy, f)
        out = subprocess.run(['node', os.path.join(HERE, 'decode.js'), schema_json] + files,
                             check=True, capture_output=True, text=True).stdout
        reference = [json.loads(line) for line in out.splitlines()]

        tool = os.path.join(tmp, 'gnrcrdr')
        subprocess.run(['odin', 'build', '.', '-out:' + tool], check=True)
        mine = []
        for path in files:
            r = subprocess.run([tool, schema, path, '--dump', 'json'], capture_output=True, text=True)
            mine.append(json.loads(r.stdout) if r.returncode == 0 else {'error': r.stderr.strip()})

    failed = 0
    for path, a, b in zip(files, mine, reference):
        if 'error' in a or 'error' in b:
            failed += 1
            print('FAILED: %s\n  gnrcrdr: %s\n  kaitai:  %s' % (path, a.get('error', 'ok'), b.get('error', 'ok')))
            continue
        first_difference.values = 0
        d = first_difference(ours(a[root_name][0]), theirs(b), root_name)
        if d:
            failed += 1
            print('DIFFERS: %s at %s\n  gnrcrdr: %s\n  kaitai:  %s' % (path, d[0], json.dumps(d[1])[:200], json.dumps(d[2])[:200]))
        else:
            print('agree: %s (%d values)' % (path, first_difference.values))

    print('%d files: %d agree, %d differ or failed' % (len(files), len(files) - failed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
