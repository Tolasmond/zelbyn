meta:
  id: main
  imports:
    - counted
seq:
  - id: n
    type: u1
  - id: items
    type: counted(n, true)
