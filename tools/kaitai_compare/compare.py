#!/usr/bin/env python3
"""Compares gnrcrdr's decode of files with the official Kaitai Struct
runtime's, value by value (decision record §8, step 6).

    python3 tools/kaitai_compare/compare.py [--import-path DIRS] [--offsets] [--param NAME=VALUE]... <schema.ksy> <file>...

Run from the repository root, after `npm ci --prefix tools/kaitai_compare`.
Needs Odin, Node.js and PyYAML. The schema is compiled with the official
compiler to JavaScript and run with the JavaScript runtime (decode.js), and
with gnrcrdr's --dump json. Both are brought to one shape: every field an
array of its values, set instances objects, byte arrays hex. Parse
instances (instances with pos) are compared as fields. A field with no
values (not read because of if or switch-on, or an empty repeat) is left
out on both sides, as are value instances and params, which gnrcrdr does
not dump. Field names are compared as the generated code spells them,
from their ids: gnrcrdr's names, which are the -orig-id where there is
one, are mapped back to the id. Integers beyond 2^53, which the
JavaScript runtime holds as doubles, are compared as doubles. A float is
compared as a number, as the runtime writes one with an integer value as
an integer, and gnrcrdr writes an f4 with the shortest digits that give
it, where the runtime writes the double it widens to: a float of
gnrcrdr's is also equal to the runtime's when it rounds to it as an f4.
Imports are read relative to the importing schema, or for an absolute one,
from the directories of --import-path (separated as in PATH), and given to
both. Each --param is an argument for a param of the schema's top-level
type, as gnrcrdr's --param takes it, given to both. Exits 1 if any file
differs, or fails to decode on either side.

With --offsets, the offsets of the values are compared instead: those of
gnrcrdr's text dump with --offsets, and the starts that the runtime
records in debug mode, which the Kaitai Web IDE shows, for every value
that is not a set instance, by its path.

The JavaScript runtime (0.11.0) reads a terminator with include: true
wrongly: with consume, it moves one byte past the terminator, and
without it, past the terminator. The C++ runtime, and gnrcrdr, consume
the terminator only with consume, so a schema with include: true can
differ after it.
"""

import argparse
import json
import os
import re
import subprocess
import struct
import sys
import tempfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))


def camel(name):
    """A .ksy id as the JavaScript compiler names it: lower_camel_case. The
    name of an attribute without an id, _unnamed and its index, is kept."""
    if name.startswith('_unnamed'):
        return name
    first, *rest = name.split('_')
    return first + ''.join(p[:1].upper() + p[1:] for p in rest)


# The id of each -orig-id in the schema and its imports, and every id
# (orig_ids).
ORIG_IDS = {}
IDS = set()


def orig_ids(ksy):
    """Adds the -orig-id of every attribute and instance of ksy, and of its
    types, to ORIG_IDS, mapped to its id, and every id to IDS."""
    entries = [(a.get('id'), a) for a in ksy.get('seq') or [] if isinstance(a, dict)]
    entries += list((ksy.get('instances') or {}).items())
    for id, spec in entries:
        IDS.add(id)
        orig = isinstance(spec, dict) and spec.get('-orig-id')
        if not orig or orig == id:
            continue
        if ORIG_IDS.setdefault(orig, id) != id:
            sys.exit('-orig-id %s is given to %s and %s, which this script cannot tell apart' % (orig, ORIG_IDS[orig], id))
    for t in (ksy.get('types') or {}).values():
        if isinstance(t, dict):
            orig_ids(t)


def name(dumped):
    """A name in gnrcrdr's dump as the generated code spells it."""
    return camel(ORIG_IDS.get(dumped, dumped))


def ours(value):
    """gnrcrdr's JSON dump of a set instance in decode.js's shape."""
    if isinstance(value, dict):
        return {name(k): [ours(x) for x in v] for k, v in value.items() if v}
    return value


def theirs(value):
    if isinstance(value, dict):
        return {k: [theirs(x) for x in v] for k, v in value.items() if v}
    return value


def read_imports(path, ksy, import_paths, out, seen):
    """Adds the schemas that ksy, read from path, imports, and theirs, to
    out, keyed as decode.js's importer is asked for them."""
    for name in (ksy.get('meta') or {}).get('imports') or []:
        if name.startswith('/'):
            key = 'abs:' + name[1:]
            found = [os.path.join(d, name[1:] + '.ksy') for d in import_paths]
            found = [f for f in found if os.path.isfile(f)]
            if not found:
                sys.exit('import %s is in none of the import paths' % name)
            file = found[0]
        else:
            key = 'rel:' + name
            file = os.path.join(os.path.dirname(path), name + '.ksy')
        real = os.path.realpath(file)
        if seen.setdefault(key, real) != real:
            sys.exit('import %s names two schemas, which decode.js cannot tell apart' % key)
        if key in out:
            continue
        with open(file, 'rb') as f:
            out[key] = yaml.safe_load(f)
        read_imports(file, out[key], import_paths, out, seen)


def as_f4(x):
    """x rounded to an f4, as a double; None when it is beyond an f4."""
    try:
        return struct.unpack('<f', struct.pack('<f', x))[0]
    except OverflowError:
        return None


def root_args(ksy, params):
    """The arguments that params, each name=value as gnrcrdr's --param takes
    it, give the params of the top-level type of ksy, in their order, as
    decode.js takes them: integers, booleans, strings, byte arrays as lists
    of integers, and for a user type, its name and the bytes it is read
    from."""
    given = dict(p.split('=', 1) for p in params)
    args = []
    for param in ksy.get('params', []):
        text, t = given[param['id']], param['type']
        if t == 'bool':
            args.append(text == 'true')
        elif t == 'bytes':
            args.append(list(bytes.fromhex(text)))
        elif t == 'str':
            args.append(text)
        elif re.fullmatch(r'[us][1248](le|be)?', t):
            args.append(int(text, 0))
        else:
            args.append({'type': t, 'bytes': list(bytes.fromhex(text))})
    return args


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
    if type(a) is int and type(b) is int and max(abs(a), abs(b)) > 2**53:
        return None if float(a) == float(b) else (path, a, b)
    if float in (type(a), type(b)) and type(a) in (int, float) and type(b) in (int, float):
        return None if a == b or as_f4(a) == b else (path, a, b)
    return None if a == b and type(a) is type(b) else (path, a, b)


def dump_offsets(text):
    """The offsets in gnrcrdr's text dump with --offsets, by path, with
    names as the generated code spells them."""
    out = {}
    for line in text.splitlines():
        path = line.split(' = ', 1)[0]
        segments = []
        for s in path.split('.'):
            field, index = s.split('[', 1)
            segments.append(name(field) + '[' + index)
        out['.'.join(segments)] = int(line.rsplit(' @0x', 1)[1], 16)
    return out


def offsets_difference(a, b):
    """The first path, in a's order, whose offset differs in b, and the two
    offsets; None when they are equal. Also counts the offsets compared."""
    for k in list(a) + [k for k in b if k not in a]:
        if a.get(k) != b.get(k):
            return k, a.get(k, '(absent)'), b.get(k, '(absent)')
        offsets_difference.values += 1
    return None


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument('--import-path', default='')
    p.add_argument('--offsets', action='store_true')
    p.add_argument('--param', action='append', default=[])
    p.add_argument('schema')
    p.add_argument('files', nargs='+')
    args = p.parse_args()
    schema, files = args.schema, args.files
    import_paths = [d for d in args.import_path.split(os.pathsep) if d]
    if not os.path.isdir(os.path.join(HERE, 'node_modules')):
        sys.exit('run npm ci --prefix tools/kaitai_compare first')

    with open(schema, 'rb') as f:
        ksy = yaml.safe_load(f)
    root_name = ksy['meta']['id']
    imports = {}
    read_imports(schema, ksy, import_paths, imports, {})
    for k in [ksy] + list(imports.values()):
        orig_ids(k)
    for orig in ORIG_IDS:
        if orig in IDS:
            sys.exit('%s is both an id and an -orig-id, which this script cannot tell apart' % orig)

    with tempfile.TemporaryDirectory() as tmp:
        schema_json = os.path.join(tmp, 'schema.json')
        with open(schema_json, 'w') as f:
            json.dump(ksy, f)
        imports_json = os.path.join(tmp, 'imports.json')
        with open(imports_json, 'w') as f:
            json.dump(imports, f)
        params = ['--params', json.dumps(root_args(ksy, args.param))] if args.param else []
        out = subprocess.run(['node', os.path.join(HERE, 'decode.js'), schema_json, '--imports', imports_json] + params + (['--offsets'] if args.offsets else []) + files,
                             check=True, capture_output=True, text=True).stdout
        reference = [json.loads(line) for line in out.splitlines()]

        tool = os.path.join(tmp, 'gnrcrdr')
        subprocess.run(['odin', 'build', '.', '-out:' + tool], check=True)
        mine = []
        for path in files:
            cmd = [tool, schema, path] + (['--offsets'] if args.offsets else ['--dump', 'json'])
            if args.import_path:
                cmd += ['--import-path', args.import_path]
            for param in args.param:
                cmd += ['--param', param]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                mine.append({'error': r.stderr.strip()})
            else:
                mine.append(dump_offsets(r.stdout) if args.offsets else json.loads(r.stdout))

    failed = 0
    for path, a, b in zip(files, mine, reference):
        if 'error' in a or 'error' in b:
            failed += 1
            print('FAILED: %s\n  gnrcrdr: %s\n  kaitai:  %s' % (path, a.get('error', 'ok'), b.get('error', 'ok')))
            continue
        if args.offsets:
            offsets_difference.values = 0
            d = offsets_difference(a, b)
            values = '%d offsets' % offsets_difference.values
        else:
            first_difference.values = 0
            d = first_difference(ours(a[root_name][0]), theirs(b), root_name)
            values = '%d values' % first_difference.values
        if d:
            failed += 1
            print('DIFFERS: %s at %s\n  gnrcrdr: %s\n  kaitai:  %s' % (path, d[0], json.dumps(d[1])[:200], json.dumps(d[2])[:200]))
        else:
            print('agree: %s (%s)' % (path, values))

    print('%d files: %d agree, %d differ or failed' % (len(files), len(files) - failed, failed))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
