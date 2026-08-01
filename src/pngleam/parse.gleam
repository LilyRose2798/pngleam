import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gzlib

pub type Error {
  InvalidSignature
  ChecksumMismatch
  MissingHeaderChunk
  MissingIENDChunk
  InvalidChunkData
  InvalidColourType
  InvalidParsedBitDepth
  InvalidCompressionType
  InvalidFilterMethod
  InvalidInterlaceMethod
  UnsupportedInterlaceMethod
  InvalidPalette
  InvalidRowFilterType
  InvalidRowData
  InvalidDeflateData
}

pub type RawChunkData {
  RawChunkData(tag: BitArray, data: BitArray, rest: BitArray)
}

pub fn chunk(data: BitArray) -> Result(RawChunkData, Error) {
  case data {
    <<
      data_size:32,
      tag:bytes-4,
      data:bytes-size(data_size),
      checksum:32,
      rest:bytes,
    >> ->
      case gzlib.crc32(tag) |> result.try(gzlib.crc32_continue(_, data)) {
        Ok(crc) if crc == checksum -> Ok(RawChunkData(tag:, data:, rest:))
        _ -> Error(ChecksumMismatch)
      }
    _ -> Error(InvalidChunkData)
  }
}

pub fn signature(data: BitArray) -> Result(BitArray, Error) {
  case data {
    <<137, 80, 78, 71, 13, 10, 26, 10, rest:bytes>> -> Ok(rest)
    _ -> Error(InvalidSignature)
  }
}

pub type ParsedHeader {
  ParsedHeader(width: Int, height: Int, colour_type_code: Int, bit_depth: Int)
}

pub fn header(header_data: BitArray) -> Result(ParsedHeader, Error) {
  case header_data {
    <<
      width:32,
      height:32,
      bit_depth,
      colour_type_code,
      compression_method,
      filter_method,
      interlace_method,
    >> -> {
      use _ <- result.try(case colour_type_code, bit_depth {
        0, 1 | 0, 2 | 0, 4 | 0, 8 | 0, 16 -> Ok(Nil)
        2, 8 | 2, 16 -> Ok(Nil)
        3, 1 | 3, 2 | 3, 4 | 3, 8 -> Ok(Nil)
        4, 8 | 4, 16 -> Ok(Nil)
        6, 8 | 6, 16 -> Ok(Nil)
        0, _ | 2, _ | 3, _ | 4, _ | 6, _ -> Error(InvalidParsedBitDepth)
        _, _ -> Error(InvalidColourType)
      })
      use <- bool.guard(
        compression_method != 0,
        return: Error(InvalidCompressionType),
      )
      use <- bool.guard(filter_method != 0, return: Error(InvalidFilterMethod))
      use <- bool.guard(
        interlace_method != 0 && interlace_method != 1,
        return: Error(InvalidInterlaceMethod),
      )
      use <- bool.guard(
        interlace_method == 1,
        Error(UnsupportedInterlaceMethod),
      )
      Ok(ParsedHeader(width:, height:, colour_type_code:, bit_depth:))
    }
    _ -> Error(InvalidChunkData)
  }
}

pub type PngDataState(rgb) {
  PngDataState(
    palette: Option(List(rgb)),
    image_data: List(BitArray),
    other_data: List(#(BitArray, BitArray)),
  )
}

pub fn do_parse_palette(
  data: BitArray,
  palette: List(rgb),
  make_rgb: fn(Int, Int, Int) -> rgb,
) -> Result(List(rgb), Nil) {
  case data {
    <<>> -> Ok(list.reverse(palette))
    <<r, g, b, data:bits>> ->
      do_parse_palette(data, [make_rgb(r, g, b), ..palette], make_rgb)
    _ -> Error(Nil)
  }
}

pub fn do_image_data(
  data: BitArray,
  state: PngDataState(rgb),
  make_rgb: fn(Int, Int, Int) -> rgb,
) -> Result(PngDataState(rgb), Error) {
  case data {
    <<>> -> Error(MissingIENDChunk)
    data ->
      case chunk(data) {
        Ok(RawChunkData(tag:, data:, rest:)) ->
          case tag {
            <<"PLTE">> ->
              case do_parse_palette(data, [], make_rgb) {
                Ok(palette) ->
                  do_image_data(
                    rest,
                    PngDataState(..state, palette: Some(palette)),
                    make_rgb,
                  )
                Error(Nil) -> Error(InvalidPalette)
              }
            <<"IDAT">> ->
              do_image_data(
                rest,
                PngDataState(..state, image_data: [data, ..state.image_data]),
                make_rgb,
              )
            <<"IEND">> if data == <<>> ->
              Ok(
                PngDataState(
                  ..state,
                  image_data: state.image_data |> list.reverse,
                  other_data: state.other_data |> list.reverse,
                ),
              )
            <<"IEND">> -> Error(InvalidChunkData)
            _ ->
              do_image_data(
                rest,
                PngDataState(..state, other_data: [
                  #(tag, data),
                  ..state.other_data
                ]),
                make_rgb,
              )
          }
        Error(e) -> Error(e)
      }
  }
}

pub fn do_add_bytewise(xs: BitArray, ys: BitArray, acc: BitArray) -> BitArray {
  case xs, ys {
    <<x, xs:bits>>, <<y, ys:bits>> ->
      do_add_bytewise(xs, ys, <<acc:bits, { x + y }>>)
    _, _ -> acc
  }
}

pub fn do_average_bytewise(
  xs: BitArray,
  ys: BitArray,
  acc: BitArray,
) -> BitArray {
  case xs, ys {
    <<x, xs:bits>>, <<y, ys:bits>> ->
      do_average_bytewise(xs, ys, <<acc:bits, { { x + y } / 2 }>>)
    _, _ -> acc
  }
}

pub fn do_paeth_bytewise(
  xs: BitArray,
  ys: BitArray,
  zs: BitArray,
  acc: BitArray,
) -> BitArray {
  case xs, ys, zs {
    <<x, xs:bits>>, <<y, ys:bits>>, <<z, zs:bits>> -> {
      let p = x + y - z
      let px = int.absolute_value(p - x)
      let py = int.absolute_value(p - y)
      let pz = int.absolute_value(p - z)
      let n = case Nil {
        _ if px <= py && px <= pz -> px
        _ if py <= pz -> py
        _ -> pz
      }
      do_paeth_bytewise(xs, ys, zs, <<acc:bits, n>>)
    }
    _, _, _ -> acc
  }
}

pub fn offset_row(row: BitArray, bpp: Int) -> BitArray {
  <<0:unit(8)-size(bpp), row:bits>>
}

pub fn previous_row(rows: List(BitArray), row_size: Int) -> BitArray {
  case rows {
    [] -> <<0:unit(8)-size(row_size)>>
    [prev, ..] -> prev
  }
}

pub fn do_image_rows(
  data: BitArray,
  row_size: Int,
  bpp: Int,
  rows: List(BitArray),
) -> Result(List(BitArray), Error) {
  case data {
    <<>> -> Ok(list.reverse(rows))
    <<filter_type, row:bytes-size(row_size), data:bits>> ->
      case filter_type {
        0 -> do_image_rows(data, row_size, bpp, [row, ..rows])
        1 ->
          do_image_rows(data, row_size, bpp, [
            do_add_bytewise(row, offset_row(row, bpp), <<>>),
            ..rows
          ])
        2 ->
          do_image_rows(data, row_size, bpp, [
            do_add_bytewise(row, previous_row(rows, row_size), <<>>),
            ..rows
          ])
        3 ->
          do_image_rows(data, row_size, bpp, [
            do_add_bytewise(
              row,
              do_average_bytewise(
                offset_row(row, bpp),
                previous_row(rows, row_size),
                <<>>,
              ),
              <<>>,
            ),
            ..rows
          ])
        4 ->
          do_image_rows(data, row_size, bpp, [
            do_add_bytewise(
              row,
              do_paeth_bytewise(
                offset_row(row, bpp),
                previous_row(rows, row_size),
                offset_row(previous_row(rows, row_size), bpp),
                <<>>,
              ),
              <<>>,
            ),
            ..rows
          ])
        _ -> Error(InvalidRowFilterType)
      }
    _ -> Error(InvalidRowData)
  }
}
