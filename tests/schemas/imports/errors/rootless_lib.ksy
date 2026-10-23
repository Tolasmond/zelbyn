# As in Kaitai, a type of this schema used from another has no _root, nor
# have the types inside it.
meta:
  id: rootless_lib
seq:
  - id: a
    type: u1
  - id: t
    type: t
types:
  t:
    seq:
      - id: u
        type: u
    types:
      u:
        seq:
          - id: b
            type: u1
            if: _root.a == 0
