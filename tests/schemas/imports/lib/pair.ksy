# Its own byte order; tag is lib/tag, relative to this file.
meta:
  id: pair
  endian: be
  imports:
    - tag
seq:
  - id: a
    type: u2
  - id: t
    type: tag
