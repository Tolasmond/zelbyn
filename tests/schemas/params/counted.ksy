# A top-level type with params, used by main.ksy.
meta:
  id: counted
params:
  - id: count
    type: u2
  - id: wide
    type: bool
seq:
  - id: values
    type: u1
    repeat: expr
    repeat-expr: count
  - id: extra
    type: u1
    if: wide
