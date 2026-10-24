#!/usr/bin/env python3
"""Tests of compare.py and decode.js, which the checks of zelbyn rely on.

    python3 tools/kaitai_compare/test_compare.py

Run from the repository root. The helpers are tested alone; the tests that
decode need what compare.py needs (Odin, Node.js, and npm ci --prefix
tools/kaitai_compare), and are skipped without node_modules.
"""

import json
import os
import struct
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

# f4 and f8 fields, repeated and in a switch-on with a case of each, which
# FLOATS_INPUT reads as f4, then f8.
FLOATS = """meta:
  id: floats
  endian: le
seq:
  - id: single
    type: f4
    repeat: expr
    repeat-expr: 2
  - id: double
    type: f8
  - id: kinds
    type: u1
    repeat: expr
    repeat-expr: 2
  - id: either
    type:
      switch-on: kinds[_index]
      cases:
        1: f4
        2: f8
    repeat: expr
    repeat-expr: 2
"""

FLOATS_INPUT = (struct.pack('<ff', 0.1, 1e-3) + struct.pack('<d', 0.1) + bytes([1, 2])
                + struct.pack('<f', 0.3) + struct.pack('<d', 0.3))

# A switch-on with integer and float cases, which MIXED_INPUT reads as u1,
# u4, f4 and f8: a u1 has no f4 or f8 width, and a u4 has an f4's, so
# neither tells a value's type, which is the case chosen. holder's parse
# instances read v[2]'s bytes again, from _root's stream, as an f4 and as a
# u4, so that two kinds of read are at one position.
MIXED = """meta:
  id: mixed
  endian: le
seq:
  - id: kinds
    type: u1
    repeat: expr
    repeat-expr: 4
  - id: v
    type:
      switch-on: kinds[_index]
      cases:
        1: u1
        2: u4
        3: f4
        4: f8
    repeat: expr
    repeat-expr: 4
  - id: sub
    size: 4
    type: holder
types:
  holder:
    seq:
      - id: raw
        type: u4
    instances:
      again:
        io: _root._io
        pos: 9
        type: f4
      as_int:
        io: _root._io
        pos: 9
        type: u4
"""

MIXED_INPUT = bytes([1, 2, 3, 4, 7]) + struct.pack('<I', 1) + struct.pack('<f', 0.3) + struct.pack('<d', 0.3) + struct.pack('<I', 5)

# Reads that start at one position: an f8 field, and parse instances that
# read its first half as an f4 and as a u4. The f8 and the f4 end apart;
# the f4 and the u4 have one span, and the f4's value is not an integer.
OVERLAP = """meta:
  id: overlap
  endian: le
seq:
  - id: wide
    type: f8
instances:
  narrow:
    pos: 0
    type: f4
  half:
    pos: 0
    type: u4
"""

OVERLAP_INPUT = struct.pack('<f', 0.1) + bytes(4)

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

    def test_float_precision(self):
        """The same numbers, as an f4 and as an f8: only an f4 is equal when
        zelbyn's rounds to the runtime's as an f4."""
        cases = [
            # zelbyn's shortest digits of an f4, and the double it widens to
            (0.1, 0.10000000149011612),
            (0.3, 0.30000001192092896),
            # doubles that differ, but round to one f4
            (1.0000000001, 1.0),
        ]
        for ours, theirs in cases:
            with self.subTest(ours=ours, theirs=theirs):
                compare.first_difference.values = 0
                self.assertIsNone(compare.first_difference(ours, theirs, 'r.x[0]', {'r.x[0]'}))
                self.assertEqual(compare.first_difference(ours, theirs, 'r.x[0]'), ('r.x[0]', ours, theirs))
                # f4 marks only its own path
                self.assertEqual(compare.first_difference(ours, theirs, 'r.x[0]', {'r.x[1]'}), ('r.x[0]', ours, theirs))
        # equal doubles, and an integer value the runtime writes as an integer
        for ours, theirs in [(0.1, 0.1), (1.0, 1), (2.5e300, 2.5e300)]:
            self.assertIsNone(compare.first_difference(ours, theirs, 'r.x[0]'))
            self.assertIsNone(compare.first_difference(ours, theirs, 'r.x[0]', {'r.x[0]'}))
        # beyond an f4, nothing rounds to it
        self.assertIsNotNone(compare.first_difference(1e300, 1e300 * (1 + 2**-40), 'r.x[0]', {'r.x[0]'}))
        # in set instances, by path
        a = {'s': [{'f': [0.1, 0.1]}]}
        b = {'s': [{'f': [0.10000000149011612, 0.10000000149011612]}]}
        self.assertIsNone(compare.first_difference(a, b, 'r', {'r.s[0].f[0]', 'r.s[0].f[1]'}))
        self.assertEqual(compare.first_difference(a, b, 'r', {'r.s[0].f[0]'}), ('r.s[0].f[1]', 0.1, 0.10000000149011612))

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
        self.assertEqual(compare.present(json.loads(out)['value']), SCOPED_VALUES)

    def test_decode_js_f4(self):
        """decode.js gives the paths of the floats read as f4s, by what was
        read: the case of a switch-on with both."""
        import yaml
        schema = self.write('s.json', json.dumps(yaml.safe_load(FLOATS)))
        out = json.loads(subprocess.run(['node', os.path.join(HERE, 'decode.js'), schema, self.write('in.bin', FLOATS_INPUT)],
                                        capture_output=True, text=True, check=True).stdout)
        self.assertEqual(out['f4'], ['floats.single[0]', 'floats.single[1]', 'floats.either[0]'])
        self.assertEqual(out['value']['double'], [0.1])
        self.assertEqual(out['value']['either'], [0.30000001192092896, 0.3])

    def test_decode_js_mixed_cases(self):
        """A value of a switch-on with integer and float cases is an f4 only
        when the case chosen is: not a u1 or a u4."""
        import yaml
        schema = self.write('s.json', json.dumps(yaml.safe_load(MIXED)))
        out = json.loads(subprocess.run(['node', os.path.join(HERE, 'decode.js'), schema, self.write('in.bin', MIXED_INPUT)],
                                        capture_output=True, text=True, check=True).stdout)
        self.assertEqual(out['f4'], ['mixed.v[2]', 'mixed.sub[0].again[0]'])
        self.assertEqual(out['value']['v'], [7, 1, 0.30000001192092896, 0.3])

    def test_decode_js_overlap(self):
        """A read is known by its span, not only where it starts: an f4 that
        starts where an f8 does is an f4."""
        import yaml
        schema = self.write('s.json', json.dumps(yaml.safe_load(OVERLAP)))
        out = json.loads(subprocess.run(['node', os.path.join(HERE, 'decode.js'), schema, self.write('in.bin', OVERLAP_INPUT)],
                                        capture_output=True, text=True, check=True).stdout)
        self.assertEqual(out['f4'], ['overlap.narrow[0]'])
        self.assertEqual(out['value']['narrow'], [0.10000000149011612])

    def test_floats_agree(self):
        for schema, data in ((FLOATS, FLOATS_INPUT), (MIXED, MIXED_INPUT), (OVERLAP, OVERLAP_INPUT)):
            for flags in ([], ['--offsets']):
                with self.subTest(schema=schema.split()[2], flags=flags):
                    r = self.compare(schema, data, *flags)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertIn('1 files: 1 agree', r.stdout)

    def test_scoped_names_agree(self):
        for flags in ([], ['--offsets']):
            r = self.compare(SCOPED, SCOPED_INPUT, *flags)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('1 files: 1 agree', r.stdout)

    def test_any_name(self):
        """A name can be one that a JavaScript object has already, or error,
        which an error record has: as a field's -orig-id or the root's, and
        constructor as an id, which would hide the object's class."""
        cases = [('n', name, 'names') for name in ('constructor', '__proto__', 'error', 'hasOwnProperty', 'toString')]
        cases += [('n', 'n', 'error'), ('constructor', 'constructor', 'names')]
        for id, shown, root in cases:
            schema = 'meta:\n  id: names\n  -orig-id: %s\nseq:\n  - id: %s\n    -orig-id: %s\n    type: u1\n' % (root, id, shown)
            for flags in ([], ['--offsets']):
                with self.subTest(id=id, shown=shown, root=root, flags=flags):
                    r = self.compare(schema, b'\x01', *flags)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertIn('1 files: 1 agree', r.stdout)

    def test_failure_reported(self):
        """A decode that fails is reported as one, on both sides, though a
        field is named error."""
        r = self.compare('meta:\n  id: names\n  endian: le\nseq:\n  - id: n\n    -orig-id: error\n    type: u2\n', b'\x01')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertRegex(r.stdout, r'FAILED: .*\n  zelbyn: error: Unexpected_EOF.*\n  kaitai:  EOFError')

    def test_difference_found(self):
        """A difference is still found, at the path zelbyn's names give."""
        r = self.compare(DIFFERING, b'ab\x00\x05\x06')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('at Differing.T[0]', r.stdout)
        self.assertIn('zelbyn: 5', r.stdout)


if __name__ == '__main__':
    unittest.main()
