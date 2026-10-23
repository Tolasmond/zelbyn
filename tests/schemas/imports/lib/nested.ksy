# Types and an enum declared inside another type, which other schemas name
# by path (nested::outer::inner).
meta:
  id: nested
  endian: le
seq:
  - id: x
    type: u1
types:
  outer:
    seq:
      - id: kind
        type: u1
        enum: kinds
      - id: in
        type: inner
    types:
      inner:
        seq:
          - id: v
            type: u2
    enums:
      kinds:
        1: one
        2: two
