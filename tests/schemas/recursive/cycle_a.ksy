meta:
  id: cycle_a
  imports:
    - cycle_b
seq:
  - id: n
    type: u1
  - id: b
    type: cycle_b
    if: n != 0
