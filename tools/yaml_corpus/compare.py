#!/usr/bin/env python3
"""Compares gnrcrdr's YAML parser with libyaml on every .ksy file under a
directory, normally a clone of
https://github.com/kaitai-io/kaitai_struct_formats.

    python3 tools/yaml_corpus/compare.py <dir>

Run from the repository root. Needs Odin and PyYAML built with libyaml
(yaml.CParser). Every file must either give the same node tree from both
parsers (kinds, scalar styles and text, and every node's line and column),
or be rejected by gnrcrdr as outside the subset (Unsupported or
Duplicate_Key), or be rejected by both. Exits 1 if any file differs.
"""

import os
import subprocess
import sys
import tempfile

import yaml

STYLE = {'': 'plain', None: 'plain', "'": 'single', '"': 'double', '|': 'literal', '>': 'folded'}


def escape(text):
    out = []
    for c in text.encode('utf-8'):
        if 0x20 <= c < 0x7f and c not in b'\\"':
            out.append(chr(c))
        else:
            out.append('\\x%02x' % c)
    return ''.join(out)


def libyaml_events(path):
    """The file's node tree in main.odin's form, or ['ERROR ...']."""
    lines = []
    try:
        with open(path, 'rb') as f:
            for e in yaml.parse(f, Loader=yaml.CLoader):
                m = e.start_mark
                pos = '%d:%d' % (m.line + 1, m.column + 1)
                if isinstance(e, yaml.ScalarEvent):
                    lines.append('SCALAR %s %s "%s"' % (pos, STYLE[e.style], escape(e.value)))
                elif isinstance(e, yaml.MappingStartEvent):
                    lines.append('MAP ' + pos)
                elif isinstance(e, yaml.SequenceStartEvent):
                    lines.append('SEQ ' + pos)
                elif isinstance(e, (yaml.MappingEndEvent, yaml.SequenceEndEvent)):
                    lines.append('END')
    except yaml.YAMLError as err:
        mark = getattr(err, 'problem_mark', None)
        where = '%d:%d' % (mark.line + 1, mark.column + 1) if mark else '?'
        return ['ERROR %s %s' % (where, getattr(err, 'problem', err))]
    return lines


def gnrcrdr_events(tool, paths):
    out = subprocess.run([tool] + paths, check=True, capture_output=True, text=True).stdout
    events, current = {}, None
    for line in out.splitlines():
        if line.startswith('== '):
            current = line[3:]
            events[current] = []
        else:
            events[current].append(line)
    return events


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    if not getattr(yaml, '__with_libyaml__', False):
        sys.exit('PyYAML is not built with libyaml')

    paths = sorted(os.path.join(d, f) for d, _, fs in os.walk(sys.argv[1]) for f in fs if f.endswith('.ksy'))

    with tempfile.TemporaryDirectory() as tmp:
        tool = os.path.join(tmp, 'yaml_corpus')
        subprocess.run(['odin', 'build', 'tools/yaml_corpus', '-out:' + tool], check=True)
        mine = gnrcrdr_events(tool, paths)

    agree, rejected, both_failed, differ = 0, [], [], []
    for path in paths:
        theirs, ours = libyaml_events(path), mine[path]
        our_reject = ours and ours[0].startswith('REJECT ')
        their_error = theirs and theirs[0].startswith('ERROR ')
        if our_reject and their_error:
            both_failed.append((path, ours[0], theirs[0]))
        elif our_reject and not ours[0].startswith('REJECT Syntax '):
            rejected.append((path, ours[0]))
        elif ours == theirs:
            agree += 1
        else:
            differ.append((path, ours, theirs))

    for path, ours in rejected:
        print('rejected (outside the subset): %s: %s' % (path, ours[7:]))
    for path, ours, theirs in both_failed:
        print('rejected by both: %s\n  gnrcrdr: %s\n  libyaml: %s' % (path, ours[7:], theirs[6:]))
    for path, ours, theirs in differ:
        i = 0
        while i < min(len(ours), len(theirs)) and ours[i] == theirs[i]:
            i += 1
        print('DIFFERS: %s, event %d\n  gnrcrdr: %s\n  libyaml: %s' % (
            path, i + 1, ours[i] if i < len(ours) else '(end)', theirs[i] if i < len(theirs) else '(end)'))

    print('%d files: %d agree, %d rejected as outside the subset, %d rejected by both, %d differ' % (
        len(paths), agree, len(rejected), len(both_failed), len(differ)))
    sys.exit(1 if differ else 0)


if __name__ == '__main__':
    main()
