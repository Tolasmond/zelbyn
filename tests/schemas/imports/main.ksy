# Imports relative to this file (lib/pair, which imports lib/tag too) and
# absolute ones (/shared/word), found in the import path tests/schemas/imports.
meta:
  id: main
  endian: le
  imports:
    - lib/pair
    - lib/tag
    - /shared/word
seq:
  - id: n
    type: u1
  - id: pairs
    type: pair
    repeat: expr
    repeat-expr: n
  - id: tag
    type: tag
  - id: word
    type: word
  - id: le
    type: u2
