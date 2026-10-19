# The top level of an imported schema has no _parent.
meta:
  id: orphan_lib
seq:
  - id: a
    type: u1
    if: _parent.x == 0
