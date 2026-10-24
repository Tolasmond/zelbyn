#!/usr/bin/env python3
"""Tests of compare.py and decode.js, which the checks of zelbyn rely on.

    python3 tools/kaitai_compare/test_compare.py

Run from the repository root. The helpers are tested alone; the tests that
decode need what compare.py needs (Odin, Node.js, and npm ci --prefix
tools/kaitai_compare), and are skipped without node_modules.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import compare  # noqa: E402

# Names zelbyn shows only in one type each: t1 and t2 give the -orig-id p
# to different attributes, t3 uses p as an id, and t4 gives two attributes,
# read under exclusive conditions, the -orig-id f, as elf.ksy does. t1 and
# t2 each declare a type inner, whose generated classes share a name: t1's
# has a param n and t2's a field n, which a list of members by class name
# would take as a param. The root has an -orig-id, which zelbyn shows.
SCOPED = """meta:
  id: scoped
  -orig-id: Scoped Root
  endian: le
seq:
  - id: a
    type: t1
  - id: b
    type: t2
  - id: c
    type: t3
  - id: d
    type: t4
types:
  t1:
    seq:
      - id: x
        -orig-id: p
        type: u1
      - id: i
        type: inner(x)
    types:
      inner:
        params:
          - id: n
            type: u1
        seq:
          - id: v
            type: u1
  t2:
    seq:
      - id: y
        -orig-id: p
        type: u1
      - id: i
        type: inner
    instances:
      at:
        -orig-id: At
        pos: 0
        type: u1
    types:
      inner:
        seq:
          - id: n
            type: u1
  t3:
    seq:
      - id: p
        type: u1
      - id: x
        -orig-id: q
        type: u1
  t4:
    seq:
      - id: kind
        type: u1
      - id: wide
        -orig-id: f
        type: u2
        if: kind == 2
      - id: narrow
        -orig-id: f
        type: u1
        if: kind != 2
"""

SCOPED_INPUT = bytes([1, 2, 3, 4, 5, 6, 1, 9])

# The values of SCOPED_INPUT, as decode.js names them: zelbyn's names.
SCOPED_VALUES = {
    'a': [{'p': [1], 'i': [{'v': [2]}]}],
    'b': [{'p': [3], 'i': [{'n': [4]}], 'At': [1]}],
    'c': [{'p': [5], 'q': [6]}],
    'd': [{'kind': [1], 'f': [9]}],
}

# The JavaScript runtime moves one byte too far past a terminator with
# include: true and consume, so after t the decoders differ.
DIFFERING = """meta:
  id: differing
  -orig-id: Differing
seq:
  - id: s
    type: strz
    encoding: ASCII
    include: true
  - id: t
    -orig-id: T
    type: u1
"""


class Helpers(unittest.TestCase):
    def test_display_name(self):
        self.assertEqual(compare.display_name({'id': 'a', '-orig-id': 'A'}, 'a'), 'A')
        self.assertEqual(compare.display_name({'id': 'a'}, 'a'), 'a')
        # a list of original names leaves the id, as zelbyn does
        self.assertEqual(compare.display_name({'id': 'a', '-orig-id': ['A32', 'A64']}, 'a'), 'a')
        self.assertEqual(compare.display_name(None, 'a'), 'a')

    def test_root_of(self):
        self.assertEqual(compare.root_of({'Root': [{'a': [1]}]}, {'meta': {'id': 'r', '-orig-id': 'Root'}}), {'a': [1]})
        self.assertEqual(compare.root_of({'r': [{'a': [1]}]}, {'meta': {'id': 'r'}}), {'a': [1]})
        with self.assertRaises(KeyError):
            compare.root_of({'r': [{}]}, {'meta': {'id': 'r', '-orig-id': 'Root'}})

    def test_merge_fields(self):
        text = '{"kind": [1], "f": [], "f": [9]}'
        self.assertEqual(json.loads(text, object_pairs_hook=compare.merge_fields), {'kind': [1], 'f': [9]})
        text = '{"f": [9], "f": []}'
        self.assertEqual(json.loads(text, object_pairs_hook=compare.merge_fields), {'f': [9]})
        with self.assertRaises(ValueError):
            json.loads('{"f": [1], "f": [2]}', object_pairs_hook=compare.merge_fields)

    def test_dump_offsets(self):
        text = 'Scoped Root[0].a[0].p[0] = 1 @0x00000000\nScoped Root[0].b[0].p[0] = 3 @0x00000002\n'
        self.assertEqual(compare.dump_offsets(text), {'Scoped Root[0].a[0].p[0]': 0, 'Scoped Root[0].b[0].p[0]': 2})
        with self.assertRaises(ValueError):
            compare.dump_offsets('r[0].f[0] = 1 @0x00000000\nr[0].f[0] = 2 @0x00000001\n')


@unittest.skipUnless(os.path.isdir(os.path.join(HERE, 'node_modules')), 'needs npm ci --prefix tools/kaitai_compare')
class Decodes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, data):
        path = os.path.join(self.tmp.name, name)
        with open(path, 'w' if isinstance(data, str) else 'wb') as f:
            f.write(data)
        return path

    def compare(self, schema, data, *flags):
        args = [sys.executable, os.path.join(HERE, 'compare.py'), *flags, self.write('s.ksy', schema), self.write('in.bin', data)]
        return subprocess.run(args, capture_output=True, text=True)

    def test_decode_js_names(self):
        """decode.js names each field as zelbyn does, by the type it is of."""
        import yaml
        schema = self.write('s.json', json.dumps(yaml.safe_load(SCOPED)))
        out = subprocess.run(['node', os.path.join(HERE, 'decode.js'), schema, self.write('in.bin', SCOPED_INPUT)],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(compare.present(json.loads(out)), SCOPED_VALUES)

    def test_scoped_names_agree(self):
        for flags in ([], ['--offsets']):
            r = self.compare(SCOPED, SCOPED_INPUT, *flags)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('1 files: 1 agree', r.stdout)

    def test_difference_found(self):
        """A difference is still found, at the path zelbyn's names give."""
        r = self.compare(DIFFERING, b'ab\x00\x05\x06')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('at Differing.T[0]', r.stdout)
        self.assertIn('zelbyn: 5', r.stdout)


if __name__ == '__main__':
    unittest.main()
