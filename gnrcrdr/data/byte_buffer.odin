package data

import "core:bytes"
import "core:encoding/endian"
import "core:log"
import "core:os"
import "core:strings"

Byte_Buffer :: struct {
  data: bytes.Buffer,
  byteOrder: endian.Byte_Order
}

destroy :: proc(buffer: ^Byte_Buffer) {
  bytes.buffer_destroy(&buffer.data)
}

get_i8 :: proc(buffer: ^Byte_Buffer) -> i8 {
  value, error := bytes.buffer_read_byte(&buffer.data)
  return i8(value)
}

get_u8 :: proc(buffer: ^Byte_Buffer) -> u8 {
  value, error := bytes.buffer_read_byte(&buffer.data)
  return value
}

get_i16 :: proc(buffer: ^Byte_Buffer) -> i16 {
  buf := bytes.buffer_next(&buffer.data, 2)
  value, ok := endian.get_i16(buf, buffer.byteOrder)
  return value
}

get_u16 :: proc(buffer: ^Byte_Buffer) -> u16 {
  buf := bytes.buffer_next(&buffer.data, 2)
  value, ok := endian.get_u16(buf, buffer.byteOrder)
  return value
}

get_i32 :: proc(buffer: ^Byte_Buffer) -> i32 {
  buf := bytes.buffer_next(&buffer.data, 4)
  value, ok := endian.get_i32(buf, buffer.byteOrder)
  return value
}

get_u32 :: proc(buffer: ^Byte_Buffer) -> u32 {
  buf := bytes.buffer_next(&buffer.data, 4)
  value, ok := endian.get_u32(buf, buffer.byteOrder)
  return value
}

get_i64 :: proc(buffer: ^Byte_Buffer) -> i64 {
  buf := bytes.buffer_next(&buffer.data, 8)
  value, ok := endian.get_i64(buf, buffer.byteOrder)
  return value
}

get_u64 :: proc(buffer: ^Byte_Buffer) -> u64 {
  buf := bytes.buffer_next(&buffer.data, 8)
  value, ok := endian.get_u64(buf, buffer.byteOrder)
  return value
}

get_f32 :: proc(buffer: ^Byte_Buffer) -> f32 {
  buf := bytes.buffer_next(&buffer.data, 4)
  value, ok := endian.get_f32(buf, buffer.byteOrder)
  return value
}

get_f64 :: proc(buffer: ^Byte_Buffer) -> f64 {
  buf := bytes.buffer_next(&buffer.data, 8)
  value, ok := endian.get_f64(buf, buffer.byteOrder)
  return value
}

get_integer :: proc(buffer: ^Byte_Buffer, data_type: Data_Type) -> (value: int, ok: bool) {
  ok = true
  #partial switch data_type {
  case .Int8: value = int(get_i8(buffer))
  case .UInt8: value = int(get_u8(buffer))
  case .Int16: value = int(get_i16(buffer))
  case .UInt16: value = int(get_u16(buffer))
  case .Int32: value = int(get_i32(buffer))
  case .UInt32: value = int(get_u32(buffer))
  case .Int64: value = int(get_i64(buffer))
  case:
    ok = false
  }
  return value, ok
}

get_string :: proc(buffer: ^Byte_Buffer, len: int) -> string {
  builder := strings.builder_make()
  defer strings.builder_destroy(&builder)
  for i in 0..<len {
    b, _ := bytes.buffer_read_byte(&buffer.data)
    if b != 0 {
      strings.write_byte(&builder,  b)
    }
  }

  value := strings.to_string(builder)
  log.debugf("Read string from buffer = %v", value)
  return strings.clone(value)
}

get_bytes :: proc(buf: ^Byte_Buffer, dest: ^[]byte) {
  for i in 0..<len(dest) {
    b, _ := bytes.buffer_read_byte(&buf.data)
    dest[i] = b
  }
}

read_file_into_buffer :: proc(buffer: ^Byte_Buffer, name: string) {
  buf, ok := os.read_entire_file_from_filename(name)
  if (ok) {
    bytes.buffer_init(&buffer.data, buf)
    delete(buf)
  }
}
