import gleam/bit_array
import gleam/list
import gzlib

pub const no_compression = gzlib.no_compression

pub const min_compression = gzlib.min_compression

pub const max_compression = gzlib.max_compression

pub const default_compression = gzlib.default_compression

pub const compression_level = gzlib.compression_level

pub type CompressionLevel =
  gzlib.CompressionLevel

pub type ColorType {
  Greyscale
  Color
  Indexed
  GreyscaleWithAlpha
  ColorWithAlpha
}

fn color_type_to_int(color_type: ColorType) -> Int {
  case color_type {
    Greyscale -> 0b000
    Color -> 0b010
    Indexed -> 0b011
    GreyscaleWithAlpha -> 0b100
    ColorWithAlpha -> 0b110
  }
}

pub opaque type ColorInfo {
  ColorInfo(color_type: ColorType, bit_depth: Int)
}

pub const greyscale_8bit = ColorInfo(Greyscale, 8)

pub const rgb_8bit = ColorInfo(Color, 8)

pub const rgb_16bit = ColorInfo(Color, 16)

pub const rgba_8bit = ColorInfo(ColorWithAlpha, 8)

pub const rgba_16bit = ColorInfo(ColorWithAlpha, 16)

pub fn color_info(
  color_type color_type: ColorType,
  bit_depth bit_depth: Int,
) -> Result(ColorInfo, Nil) {
  let color_info = Ok(ColorInfo(color_type, bit_depth))
  case color_type, bit_depth {
    Greyscale, 1 | Greyscale, 2 | Greyscale, 4 | Greyscale, 8 | Greyscale, 16 ->
      color_info
    Color, 8 | Color, 16 -> color_info
    Indexed, 1 | Indexed, 2 | Indexed, 4 | Indexed, 8 -> color_info
    GreyscaleWithAlpha, 8 | GreyscaleWithAlpha, 16 -> color_info
    ColorWithAlpha, 8 | ColorWithAlpha, 16 -> color_info
    _, _ -> Error(Nil)
  }
}

fn chunk_bit_array(data: BitArray) -> List(BitArray) {
  do_chunk_bit_array(data, []) |> list.reverse
}

fn do_chunk_bit_array(data: BitArray, chunks: List(BitArray)) -> List(BitArray) {
  case data {
    <<chunk:bytes-size(8192), rest:bytes>> ->
      do_chunk_bit_array(rest, [chunk, ..chunks])
    chunk -> [chunk, ..chunks]
  }
}

fn get_chunk(tag: String, data: BitArray) -> BitArray {
  let data_size = bit_array.byte_size(data)
  let tag_bits = <<tag:utf8>>
  let checksum = gzlib.continue_crc32(gzlib.crc32(tag_bits), data)
  <<data_size:size(32), tag_bits:bits, data:bits, checksum:size(32)>>
}

const signature = <<137, "PNG":utf8, "\r\n":utf8, 26, "\n":utf8>>

pub fn from_packed(
  row_data row_data: List(BitArray),
  width width: Int,
  height height: Int,
  color_info color_info: ColorInfo,
  compression_level compression_level: gzlib.CompressionLevel,
) -> BitArray {
  let ihdr =
    get_chunk("IHDR", <<
      width:size(32),
      height:size(32),
      color_info.bit_depth:size(8),
      color_type_to_int(color_info.color_type):size(8),
      0:size(8),
      0:size(8),
      0:size(8),
    >>)
  let idats =
    row_data
    |> list.map(fn(d) { <<0, d:bits>> })
    |> bit_array.concat
    |> gzlib.compress_with_level(compression_level)
    |> chunk_bit_array
    |> list.map(get_chunk("IDAT", _))
    |> bit_array.concat
  let iend = get_chunk("IEND", <<>>)
  <<signature:bits, ihdr:bits, idats:bits, iend:bits>>
}
