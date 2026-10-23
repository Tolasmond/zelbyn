# Types and enums of other types, by path: those of an imported schema,
# which keep its meta, and of this one, which are inside this schema's
# instances as any other type.
meta:
  id: paths
  endian: be
  imports:
    - lib/nested
seq:
  - id: o
    type: nested::outer
  - id: i
    type: nested::outer::inner
  - id: k
    type: u1
    enum: nested::outer::kinds
    valid:
      in-enum: true
  - id: skipped
    size: sizeof<nested::outer::inner>
  - id: h
    type: holder(o)
  - id: local
    type: t::u
  # sizes that show the value instances
  - id: by_enum
    size: 'is_two ? 1 : 3'
  - id: by_param
    size: h.kind.to_i
  - id: by_root
    size: local.r.to_i
instances:
  is_two:
    value: k == nested::outer::kinds::two
types:
  holder:
    params:
      - id: of
        type: nested::outer
    instances:
      kind:
        value: of.kind
  t:
    types:
      u:
        seq:
          - id: p
            type: u1
            if: _parent.k == nested::outer::kinds::two
        instances:
          r:
            value: _root.k
