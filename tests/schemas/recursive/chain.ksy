meta:
  id: chain
seq:
  - id: n
    type: u1
  - id: next
    type: chain
    if: _root.n != 0
