import gleam/bit_array
import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/result
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

fn int_to_color_type(color_type: Int) -> Result(ColorType, Nil) {
  case color_type {
    0b000 -> Ok(Greyscale)
    0b010 -> Ok(Color)
    0b011 -> Ok(Indexed)
    0b100 -> Ok(GreyscaleWithAlpha)
    0b110 -> Ok(ColorWithAlpha)
    _ -> Error(Nil)
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

pub fn color_info_bits(color_info: ColorInfo) -> Int {
  case color_info.color_type {
    Greyscale -> color_info.bit_depth
    Color -> 3 * color_info.bit_depth
    Indexed -> color_info.bit_depth
    GreyscaleWithAlpha -> 2 * color_info.bit_depth
    ColorWithAlpha -> 4 * color_info.bit_depth
  }
}

fn partition_bit_array(
  data: BitArray,
  at bytes: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  use left <- result.try(bit_array.slice(data, 0, bytes))
  use right <- result.try(bit_array.slice(
    data,
    bytes,
    bit_array.byte_size(data) - bytes,
  ))
  Ok(#(left, right))
}

const chunk_size = 8192

fn do_chunk_bit_array(data: BitArray, chunks: List(BitArray)) -> List(BitArray) {
  case partition_bit_array(data, chunk_size) {
    Ok(#(chunk, rest)) -> do_chunk_bit_array(rest, [chunk, ..chunks])
    _ -> [data, ..chunks]
  }
}

fn chunk_bit_array(data: BitArray) -> List(BitArray) {
  do_chunk_bit_array(data, []) |> list.reverse
}

fn create_chunk(tag: String, data: BitArray) -> BitArray {
  let data_size = bit_array.byte_size(data)
  let tag_bits = bit_array.from_string(tag)
  let checksum = gzlib.continue_crc32(gzlib.crc32(tag_bits), data)
  <<data_size:size(32), tag_bits:bits, data:bits, checksum:size(32)>>
}

const signature = <<137, 80, 78, 71, 13, 10, 26, 10>>

pub type BinaryRowData =
  List(BitArray)

pub fn from_packed(
  row_data row_data: BinaryRowData,
  width width: Int,
  height height: Int,
  color_info color_info: ColorInfo,
  compression_level compression_level: gzlib.CompressionLevel,
) -> BitArray {
  let ihdr =
    create_chunk("IHDR", <<
      width:size(32),
      height:size(32),
      color_info.bit_depth:size(8),
      color_type_to_int(color_info.color_type):size(8),
      0:size(8),
      0:size(8),
      0:size(8),
    >>)
  let no_filter_int = filter_type_to_int(None)
  let idats =
    row_data
    |> list.map(fn(d) { <<no_filter_int:size(8), d:bits>> })
    |> bit_array.concat
    |> gzlib.compress_with_level(compression_level)
    |> chunk_bit_array
    |> list.map(create_chunk("IDAT", _))
    |> bit_array.concat
  let iend = create_chunk("IEND", <<>>)
  <<signature:bits, ihdr:bits, idats:bits, iend:bits>>
}

pub type ParseError {
  InvalidSignature
  InvalidChunkTag
  ChecksumMismatch
  InvalidChunkOrder
  MissingHeaderChunk
  InvalidChunkData
  InvalidColorType
  InvalidBitDepth
  InvalidCompressionType
  InvalidFilterMethod
  InvalidInterlaceMethod
  UnsupportedInterlaceMethod
  InvalidRowFilterType
  InvalidRowData
}

fn parse_chunk(
  data: BitArray,
) -> Result(#(String, BitArray, BitArray), ParseError) {
  case data {
    <<data_size:size(32), tag_bits:bytes-size(4), rest:bytes>> -> {
      use tag <- result.try(
        bit_array.to_string(tag_bits)
        |> result.replace_error(InvalidChunkTag),
      )
      case partition_bit_array(rest, data_size) {
        Ok(#(data, <<checksum:size(32), rest:bytes>>)) -> {
          let computed_checksum =
            gzlib.continue_crc32(gzlib.crc32(tag_bits), data)
          use <- bool.guard(
            computed_checksum != checksum,
            Error(ChecksumMismatch),
          )
          Ok(#(tag, data, rest))
        }
        _ -> Error(InvalidChunkData)
      }
    }
    _ -> Error(InvalidChunkData)
  }
}

fn parse_signature(data: BitArray) -> Result(BitArray, ParseError) {
  case data {
    <<137, 80, 78, 71, 13, 10, 26, 10, rest:bytes>> -> Ok(rest)
    _ -> Error(InvalidSignature)
  }
}

pub type PngMetadata {
  PngMetadata(width: Int, height: Int, color_info: ColorInfo)
}

fn parse_header(header_data: BitArray) -> Result(PngMetadata, ParseError) {
  case header_data {
    <<
      width:size(32),
      height:size(32),
      bit_depth:size(8),
      color_type:size(8),
      compression_method:size(8),
      filter_method:size(8),
      interlace_method:size(8),
    >> -> {
      use col_type <- result.try(
        int_to_color_type(color_type)
        |> result.replace_error(InvalidColorType),
      )
      use col_info <- result.try(
        color_info(col_type, bit_depth)
        |> result.replace_error(InvalidBitDepth),
      )
      use <- bool.guard(compression_method != 0, Error(InvalidCompressionType))
      use <- bool.guard(filter_method != 0, Error(InvalidFilterMethod))
      use <- bool.guard(
        interlace_method != 0 && interlace_method != 1,
        Error(InvalidInterlaceMethod),
      )
      use <- bool.guard(
        interlace_method == 1,
        Error(UnsupportedInterlaceMethod),
      )
      Ok(PngMetadata(width, height, col_info))
    }
    _ -> Error(InvalidChunkData)
  }
}

pub fn parse_metadata(data: BitArray) -> Result(PngMetadata, ParseError) {
  use chunk_data <- result.try(parse_signature(data))
  use #(tag, chunk_data, _) <- result.try(parse_chunk(chunk_data))
  use <- bool.guard(tag != "IHDR", Error(MissingHeaderChunk))
  parse_header(chunk_data)
}

pub type RawPalette =
  BitArray

type PngDataState {
  PngDataState(palette: option.Option(RawPalette), image_parts: BinaryRowData)
}

fn do_parse_image_data(
  data: BitArray,
  state: PngDataState,
) -> Result(PngDataState, ParseError) {
  use #(tag, chunk_data, rest) <- result.try(parse_chunk(data))
  case tag, state.image_parts {
    "PLTE", [] ->
      do_parse_image_data(
        rest,
        PngDataState(..state, palette: option.Some(chunk_data)),
      )
    "PLTE", _ -> Error(InvalidChunkOrder)
    "IDAT", parts ->
      do_parse_image_data(
        rest,
        PngDataState(..state, image_parts: [chunk_data, ..parts]),
      )
    "IEND", _ -> Ok(state)
    _, [] -> do_parse_image_data(rest, state)
    _, _ -> Ok(state)
  }
}

fn parse_image_data(data: BitArray) -> Result(PngDataState, ParseError) {
  do_parse_image_data(data, PngDataState(option.None, []))
}

pub type FilterType {
  None
  Sub
  Up
  Average
  Paeth
}

pub fn int_to_filter_type(filter_type: Int) -> Result(FilterType, Nil) {
  case filter_type {
    0 -> Ok(None)
    1 -> Ok(Sub)
    2 -> Ok(Up)
    3 -> Ok(Average)
    4 -> Ok(Paeth)
    _ -> Error(Nil)
  }
}

pub fn filter_type_to_int(filter_type: FilterType) -> Int {
  case filter_type {
    None -> 0
    Sub -> 1
    Up -> 2
    Average -> 3
    Paeth -> 4
  }
}

@external(erlang, "pngleam_erl", "subUnfilter")
@external(javascript, "./pngleam_js.mjs", "subUnfilter")
fn sub_unfilter(row: BitArray, bytes_per_pixel: Int) -> BitArray

@external(erlang, "pngleam_erl", "upUnfilter")
@external(javascript, "./pngleam_js.mjs", "upUnfilter")
fn up_unfilter(row: BitArray, row_above: BitArray) -> BitArray

@external(erlang, "pngleam_erl", "avgUnfilter")
@external(javascript, "./pngleam_js.mjs", "avgUnfilter")
fn avg_unfilter(
  row: BitArray,
  row_above: BitArray,
  bytes_per_pixel: Int,
) -> BitArray

@external(erlang, "pngleam_erl", "paethUnfilter")
@external(javascript, "./pngleam_js.mjs", "paethUnfilter")
fn paeth_unfilter(
  row: BitArray,
  row_above: BitArray,
  bytes_per_pixel: Int,
) -> BitArray

fn do_parse_image_rows(
  data: BitArray,
  bytes_per_row: Int,
  bytes_per_pixel: Int,
  rows: BinaryRowData,
) -> Result(BinaryRowData, ParseError) {
  let bits_per_row = bytes_per_row * 8
  case data {
    <<>> -> Ok(rows)
    <<filter_type:size(8), rest:bytes>> -> {
      use filter_type <- result.try(
        int_to_filter_type(filter_type)
        |> result.replace_error(InvalidRowFilterType),
      )
      use #(row, rest) <- result.try(
        partition_bit_array(rest, bytes_per_row)
        |> result.replace_error(InvalidRowData),
      )
      let row = case filter_type {
        None -> row
        Sub -> sub_unfilter(row, bytes_per_pixel)
        Up ->
          up_unfilter(
            row,
            result.unwrap(list.first(rows), <<0:size(bits_per_row)>>),
          )
        Average ->
          avg_unfilter(
            row,
            result.unwrap(list.first(rows), <<0:size(bits_per_row)>>),
            bytes_per_pixel,
          )
        Paeth ->
          paeth_unfilter(
            row,
            result.unwrap(list.first(rows), <<0:size(bits_per_row)>>),
            bytes_per_pixel,
          )
      }
      do_parse_image_rows(rest, bytes_per_row, bytes_per_pixel, [row, ..rows])
    }
    _ -> Error(InvalidRowData)
  }
}

fn parse_image_rows(
  data: BitArray,
  bytes_per_row: Int,
  bytes_per_pixel: Int,
) -> Result(BinaryRowData, ParseError) {
  do_parse_image_rows(data, bytes_per_row, bytes_per_pixel, [])
  |> result.map(list.reverse)
}

fn bits_to_bytes(bits: Int) -> Int {
  bits
  |> int.to_float
  |> fn(x) { x /. 8.0 }
  |> float.ceiling
  |> float.round
}

pub type PngData(p, i) {
  PngData(metadata: PngMetadata, palette: option.Option(p), image_data: i)
}

pub type PngBitArrayData =
  PngData(RawPalette, BinaryRowData)

pub fn parse_to_bit_arrays(
  data: BitArray,
) -> Result(PngBitArrayData, ParseError) {
  use rest <- result.try(parse_signature(data))
  use #(tag, chunk_data, rest) <- result.try(parse_chunk(rest))
  use <- bool.guard(tag != "IHDR", Error(MissingHeaderChunk))
  use metadata <- result.try(parse_header(chunk_data))
  use PngDataState(palette, image_parts) <- result.try(parse_image_data(rest))
  let image_data =
    image_parts
    |> list.reverse
    |> bit_array.concat
    |> gzlib.uncompress
  let bits_per_pixel = color_info_bits(metadata.color_info)
  let bytes_per_row = bits_to_bytes(metadata.width * bits_per_pixel)
  let bytes_per_pixel = bits_to_bytes(bits_per_pixel)
  use idat_rows <- result.try(parse_image_rows(
    image_data,
    bytes_per_row,
    bytes_per_pixel,
  ))
  Ok(PngData(metadata, palette, idat_rows))
}

@external(erlang, "pngleam_erl", "bitArrayToInts")
@external(javascript, "./pngleam_js.mjs", "bitArrayToInts")
fn bit_array_to_ints(data: BitArray, int_size: Int) -> List(Int)

fn do_chunk2(
  values: List(a),
  chunks: List(#(a, a)),
) -> Result(List(#(a, a)), Nil) {
  case values {
    [] -> Ok(chunks)
    [a, b, ..rest] -> do_chunk2(rest, [#(a, b), ..chunks])
    _ -> Error(Nil)
  }
}

fn chunk2(values: List(a)) -> Result(List(#(a, a)), Nil) {
  do_chunk2(values, []) |> result.map(list.reverse)
}

fn do_chunk3(
  values: List(a),
  chunks: List(#(a, a, a)),
) -> Result(List(#(a, a, a)), Nil) {
  case values {
    [] -> Ok(chunks)
    [a, b, c, ..rest] -> do_chunk3(rest, [#(a, b, c), ..chunks])
    _ -> Error(Nil)
  }
}

fn chunk3(values: List(a)) -> Result(List(#(a, a, a)), Nil) {
  do_chunk3(values, []) |> result.map(list.reverse)
}

fn do_chunk4(
  values: List(a),
  chunks: List(#(a, a, a, a)),
) -> Result(List(#(a, a, a, a)), Nil) {
  case values {
    [] -> Ok(chunks)
    [a, b, c, d, ..rest] -> do_chunk4(rest, [#(a, b, c, d), ..chunks])
    _ -> Error(Nil)
  }
}

fn chunk4(values: List(a)) -> Result(List(#(a, a, a, a)), Nil) {
  do_chunk4(values, []) |> result.map(list.reverse)
}

pub type GreyscaleValue =
  Int

pub type ColorValue =
  #(Int, Int, Int)

pub type PalleteIndex =
  Int

pub type GreyscaleWithAlphaValue =
  #(Int, Int)

pub type ColorWithAlphaValue =
  #(Int, Int, Int, Int)

pub type Grid(a) =
  List(List(a))

pub type PixelData {
  GreyscaleData(Grid(GreyscaleValue))
  ColorData(Grid(ColorValue))
  IndexedData(Grid(PalleteIndex))
  GreyscaleWithAlphaData(Grid(GreyscaleWithAlphaValue))
  ColorWithAlphaData(Grid(ColorWithAlphaValue))
}

pub type PaletteColor =
  #(Int, Int, Int)

pub type PaletteColors =
  List(PaletteColor)

pub type PngPixelData =
  PngData(PaletteColors, PixelData)

pub fn parse_to_pixel_data(data: BitArray) -> Result(PngPixelData, ParseError) {
  use PngData(metadata, palette, row_data) <- result.try(parse_to_bit_arrays(
    data,
  ))
  use palette <- result.try(case palette {
    option.Some(p) ->
      case bit_array_to_ints(p, 8) |> chunk3 {
        Ok(p) -> Ok(option.Some(p))
        Error(_) -> Error(InvalidChunkData)
      }
    option.None -> Ok(option.None)
  })
  let bit_depth = metadata.color_info.bit_depth
  let num_values =
    metadata.width * color_info_bits(metadata.color_info) / bit_depth
  let values =
    list.map(row_data, fn(row) {
      bit_array_to_ints(row, bit_depth) |> list.take(num_values)
    })
  use image_data <- result.try(
    case metadata.color_info.color_type {
      Greyscale -> Ok(GreyscaleData(values))
      Color -> list.try_map(values, chunk3) |> result.map(ColorData)
      Indexed -> Ok(IndexedData(values))
      GreyscaleWithAlpha ->
        list.try_map(values, chunk2) |> result.map(GreyscaleWithAlphaData)
      ColorWithAlpha ->
        list.try_map(values, chunk4) |> result.map(ColorWithAlphaData)
    }
    |> result.replace_error(InvalidRowData),
  )
  Ok(PngData(metadata, palette, image_data))
}
