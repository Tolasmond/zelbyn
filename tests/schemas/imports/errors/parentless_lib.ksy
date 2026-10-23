# As in Kaitai, a type of this schema used from another has no _parent.
meta:
  id: parentless_lib
seq:
  - id: x
    type: u1
  - id: t
    type: t
types:
  t:
    seq:
      - id: b
        type: u1
        if: _parent.x == 0
