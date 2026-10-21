meta:
  id: cycle_b
  imports:
    - cycle_a
seq:
  - id: m
    type: u1
  - id: a
    type: cycle_a
    if: m != 0
