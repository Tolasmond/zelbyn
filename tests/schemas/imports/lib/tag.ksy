# _root in an imported schema is the instance of its top level.
meta:
  id: tag
seq:
  - id: v
    type: u1
  - id: inner
    type: inner
types:
  inner:
    seq:
      - id: w
        type: u1
        if: _root.v == 1
    instances:
      first:
        pos: 0
        type: u1
