# GIF89a, ported field for field from the SQLite schema zelbyn used before
# .ksy (format 1 of data/Gif89aMetadata.sqlite3, removed in step 7). Each
# field keeps its SQLite name in -orig-id, so the dumps match the SQLite
# schema's byte for byte. The SQLite schema's look-ahead markers and
# growing sets are -peek, -while-peek and -until-peek, and its packed fields
# are -bits. Its counting rules peeked at the packed bytes; here they name
# them. Ranges that every value of the type is within (0 to 255 on a u1),
# and the default values, are not ported: nothing checks or uses them.
meta:
  id: gif89a
  -orig-id: GIF89a
  endian: le
  encoding: ASCII
seq:
  - id: signature
    -orig-id: Signature
    type: str
    size: 3
    valid: '"GIF"'
  - id: version
    -orig-id: Version
    type: str
    size: 3
    valid: '"89a"'
  - id: logical_screen_descriptor
    -orig-id: Logical Screen Descriptor
    type: logical_screen_descriptor
  - id: global_color_table
    -orig-id: Global Color Table
    type: color_table_entry
    repeat: expr
    repeat-expr: |
      (logical_screen_descriptor.logical_screen_descriptor_packed_fields & 0x80) != 0
        ? 2 << (logical_screen_descriptor.logical_screen_descriptor_packed_fields & 7)
        : 0
  - id: blocks
    -orig-id: Blocks
    type: block
    -until-peek: [0x3b]
  - id: trailer
    -orig-id: Trailer
    type: u1
    valid: 0x3b
types:
  logical_screen_descriptor:
    seq:
      - id: logical_screen_width
        -orig-id: Logical Screen Width
        type: u2
      - id: logical_screen_height
        -orig-id: Logical Screen Height
        type: u2
      - id: logical_screen_descriptor_packed_fields
        -orig-id: Logical Screen Descriptor Packed Fields
        type: u1
        -bits:
          - id: size_of_global_color_table
            -orig-id: Size of Global Color Table
            low: 0
            high: 2
          - id: sort_flag
            -orig-id: Sort Flag
            low: 3
            high: 3
          - id: color_resolution
            -orig-id: Color Resolution
            low: 4
            high: 6
          - id: global_color_table_flag
            -orig-id: Global Color Table Flag
            low: 7
            high: 7
      - id: background_color_index
        -orig-id: Background Color Index
        type: u1
      - id: pixel_aspect_ratio
        -orig-id: Pixel Aspect Ratio
        type: u1
  color_table_entry:
    seq:
      - id: red
        -orig-id: Red
        type: u1
      - id: green
        -orig-id: Green
        type: u1
      - id: blue
        -orig-id: Blue
        type: u1
  block:
    seq:
      - id: extensions
        -orig-id: Extensions
        type: extension
        -while-peek: [0x21]
      - id: image
        -orig-id: Image
        type: image
        -peek: [0x2c]
  extension:
    seq:
      - id: graphic_control_extension
        -orig-id: Graphic Control Extension
        type: graphic_control_extension
        -peek: [0x21, 0xf9]
      - id: comment_extension
        -orig-id: Comment Extension
        type: comment_extension
        -peek: [0x21, 0xfe]
      - id: plain_text_extension
        -orig-id: Plain Text Extension
        type: plain_text_extension
        -peek: [0x21, 0x01]
      - id: application_extension
        -orig-id: Application Extension
        type: application_extension
        -peek: [0x21, 0xff]
  graphic_control_extension:
    seq:
      - id: extension_introducer
        -orig-id: Extension Introducer
        type: u1
        valid: 0x21
      - id: graphic_control_label
        -orig-id: Graphic Control Label
        type: u1
        valid: 0xf9
      - id: graphic_control_block_size
        -orig-id: Graphic Control Block Size
        type: u1
        valid: 4
      - id: graphic_control_extension_packed_fields
        -orig-id: Graphic Control Extension Packed Fields
        type: u1
        -bits:
          - id: transparent_color_flag
            -orig-id: Transparent Color Flag
            low: 0
            high: 0
          - id: user_input_flag
            -orig-id: User Input Flag
            low: 1
            high: 1
          - id: disposal_method
            -orig-id: Disposal Method
            low: 2
            high: 4
      - id: delay_time
        -orig-id: Delay Time
        type: u2
      - id: transparent_color_index
        -orig-id: Transparent Color Index
        type: u1
      - id: block_terminator
        -orig-id: Block Terminator
        type: u1
        valid: 0
  comment_extension:
    seq:
      - id: extension_introducer
        -orig-id: Extension Introducer
        type: u1
        valid: 0x21
      - id: comment_label
        -orig-id: Comment Label
        type: u1
        valid: 0xfe
      - id: comment_data
        -orig-id: Comment Data
        type: data_sub_block
        -until-peek: [0]
      - id: block_terminator
        -orig-id: Block Terminator
        type: u1
        valid: 0
  plain_text_extension:
    seq:
      - id: extension_introducer
        -orig-id: Extension Introducer
        type: u1
        valid: 0x21
      - id: plain_text_label
        -orig-id: Plain Text Label
        type: u1
        valid: 0x01
      - id: plain_text_block_size
        -orig-id: Plain Text Block Size
        type: u1
        valid: 12
      - id: text_grid_left_position
        -orig-id: Text Grid Left Position
        type: u2
      - id: text_grid_top_position
        -orig-id: Text Grid Top Position
        type: u2
      - id: text_grid_width
        -orig-id: Text Grid Width
        type: u2
      - id: text_grid_height
        -orig-id: Text Grid Height
        type: u2
      - id: character_cell_width
        -orig-id: Character Cell Width
        type: u1
      - id: character_cell_height
        -orig-id: Character Cell Height
        type: u1
      - id: text_foreground_color_index
        -orig-id: Text Foreground Color Index
        type: u1
      - id: text_background_color_index
        -orig-id: Text Background Color Index
        type: u1
      - id: plain_text_data
        -orig-id: Plain Text Data
        type: data_sub_block
        -until-peek: [0]
      - id: block_terminator
        -orig-id: Block Terminator
        type: u1
        valid: 0
  application_extension:
    seq:
      - id: extension_introducer
        -orig-id: Extension Introducer
        type: u1
        valid: 0x21
      - id: application_label
        -orig-id: Application Label
        type: u1
        valid: 0xff
      - id: application_block_size
        -orig-id: Application Block Size
        type: u1
        valid: 11
      - id: application_identifier
        -orig-id: Application Identifier
        type: str
        size: 8
      - id: application_authentication_code
        -orig-id: Application Authentication Code
        size: 3
      - id: application_data
        -orig-id: Application Data
        type: data_sub_block
        -until-peek: [0]
      - id: block_terminator
        -orig-id: Block Terminator
        type: u1
        valid: 0
  data_sub_block:
    seq:
      - id: data_sub_block_size
        -orig-id: Data Sub-Block Size
        type: u1
      - id: data_sub_block_values
        -orig-id: Data Sub-Block Values
        size: data_sub_block_size
  image:
    seq:
      - id: image_descriptor
        -orig-id: Image Descriptor
        type: image_descriptor
      - id: local_color_table
        -orig-id: Local Color Table
        type: color_table_entry
        repeat: expr
        repeat-expr: |
          (image_descriptor.image_descriptor_packed_fields & 0x80) != 0
            ? 2 << (image_descriptor.image_descriptor_packed_fields & 7)
            : 0
      - id: table_based_image_data
        -orig-id: Table Based Image Data
        type: table_based_image_data
  image_descriptor:
    seq:
      - id: image_separator
        -orig-id: Image Separator
        type: u1
        valid: 0x2c
      - id: image_left_position
        -orig-id: Image Left Position
        type: u2
      - id: image_top_position
        -orig-id: Image Top Position
        type: u2
      - id: image_width
        -orig-id: Image Width
        type: u2
      - id: image_height
        -orig-id: Image Height
        type: u2
      - id: image_descriptor_packed_fields
        -orig-id: Image Descriptor Packed Fields
        type: u1
        -bits:
          - id: size_of_local_color_table
            -orig-id: Size of Local Color Table
            low: 0
            high: 2
          - id: sort_flag
            -orig-id: Sort Flag
            low: 5
            high: 5
          - id: interlace_flag
            -orig-id: Interlace Flag
            low: 6
            high: 6
          - id: local_color_table_flag
            -orig-id: Local Color Table Flag
            low: 7
            high: 7
  table_based_image_data:
    seq:
      - id: lzw_minimum_code_size
        -orig-id: LZW Minimum Code Size
        type: u1
      - id: image_data
        -orig-id: Image Data
        type: data_sub_block
        -until-peek: [0]
      - id: block_terminator
        -orig-id: Block Terminator
        type: u1
        valid: 0
