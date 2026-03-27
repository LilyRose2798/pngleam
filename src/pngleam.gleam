import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gzlib

/// The parsed contents of a PNG image.
pub type PngImage {
  PngImage(
    metadata: PngMetadata,
    palette: Option(List(Rgb)),
    image_data: List(BitArray),
    other_data: List(#(BitArray, BitArray)),
  )
}

/// The information found in the initial header (IHDR) chunk of a PNG image.
pub type PngMetadata {
  PngMetadata(width: Int, height: Int, colour_type: ColourType, bit_depth: Int)
}

/// The type of colour used for a PNG image.
pub type ColourType {
  Indexed
  Greyscale(alpha: Bool)
  Colour(alpha: Bool)
}

/// A representation of any possible colour value that
/// can be contained within a PNG image.
pub type ColourData {
  IndexedData(i: Int)
  GreyscaleData(v: Int, a: Option(Int))
  ColourData(r: Int, g: Int, b: Int, a: Option(Int))
}

/// A colour with greyscale and alpha components.
pub type Va {
  Va(v: Int, a: Int)
}

/// A colour with red, green, and blue components.
pub type Rgb {
  Rgb(r: Int, g: Int, b: Int)
}

/// A colour with red, green, blue, and alpha components.
pub type Rgba {
  Rgba(r: Int, g: Int, b: Int, a: Int)
}

/// The possible error states when creating a new PNG image.
pub type PngRenderError {
  UnalignedData
  InvalidBitDepth
  InvalidCompressionLevel
}

/// The possible error states when parsing a PNG image.
pub type PngParseError {
  InvalidSignature
  ChecksumMismatch
  MissingHeaderChunk
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

fn do_chunk_bits(data: BitArray, chunks: List(BitArray)) -> List(BitArray) {
  case data {
    <<chunk:bytes-8192, rest:bits>> -> do_chunk_bits(rest, [chunk, ..chunks])
    _ -> list.reverse([data, ..chunks])
  }
}

fn render_chunk(
  tag: BitArray,
  data: BitArray,
) -> Result(BitArray, PngRenderError) {
  case gzlib.crc32(tag) |> result.try(gzlib.crc32_continue(_, data)) {
    Ok(checksum) ->
      Ok(<<bit_array.byte_size(data):32, tag:bits, data:bits, checksum:32>>)
    Error(Nil) -> Error(UnalignedData)
  }
}

const signature = <<137, 80, 78, 71, 13, 10, 26, 10>>

/// Create a PNG image from a bit array containing raw uncompressed pixel data.
/// 
/// The data should already have the necessary byte at the start of
/// each line specifying the filter type used for the data of that line
/// as this will not be added and the data will be compressed as-is, chunked, and
/// then put in the final image.
/// 
/// The compression level should either be some value between 0 (no compression)
/// and 9 (maximum compression) or be None to be left at the default
/// compression level (typically around 6).
pub fn render_png_raw_data(
  data data: BitArray,
  width width: Int,
  height height: Int,
  colour_type colour_type: ColourType,
  bit_depth bit_depth: Int,
  palette palette: Option(List(Rgb)),
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  use _ <- result.try(case colour_type, bit_depth {
    _, 8
    | Indexed, 1
    | Indexed, 2
    | Indexed, 4
    | Greyscale(False), 1
    | Greyscale(False), 2
    | Greyscale(False), 4
    | Greyscale(_), 16
    | Colour(_), 16
    -> Ok(Nil)
    _, _ -> Error(InvalidBitDepth)
  })
  use compress <- result.try(case compression_level {
    Some(level) if level < 0 || level > 9 -> Error(InvalidCompressionLevel)
    Some(level) -> Ok(gzlib.compress_custom(_, level:))
    None -> Ok(gzlib.compress)
  })
  use ihdr <- result.try(
    render_chunk(<<"IHDR">>, <<
      width:32,
      height:32,
      bit_depth,
      case colour_type {
        Greyscale(False) -> 0
        Colour(False) -> 2
        Indexed -> 3
        Greyscale(True) -> 4
        Colour(True) -> 6
      },
      0,
      0,
      0,
    >>),
  )
  use plte <- result.try(case palette {
    Some(palette) ->
      render_chunk(<<"PLTE">>, list.fold(palette, <<>>, render_rgb(8)))
    None -> Ok(<<>>)
  })
  use compressed <- result.try(
    compress(data)
    |> result.replace_error(UnalignedData),
  )
  use idats <- result.try(
    do_chunk_bits(compressed, [])
    |> list.try_map(render_chunk(<<"IDAT">>, _))
    |> result.map(bit_array.concat),
  )
  use iend <- result.try(render_chunk(<<"IEND">>, <<>>))
  Ok(<<
    signature:bits,
    ihdr:bits,
    plte:bits,
    idats:bits,
    iend:bits,
  >>)
}

fn do_flatten_rows(rows: List(BitArray), acc: BitArray) -> BitArray {
  case rows {
    [] -> acc
    [row, ..rows] -> do_flatten_rows(rows, <<acc:bits, 0, row:bits>>)
  }
}

/// Create a PNG image from a list of BitArrays each representing the
/// raw uncompressed pixel data of a single row of the image (from top to bottom).
/// 
/// No filtering will be applied to the line data, so if a specific filter type is
/// desired then the `render_png_raw_data` function should be used with the filtering
/// already applied to each line.
/// 
/// The compression level should either be some value between 0 (no compression)
/// and 9 (maximum compression) or be None to be left at the default
/// compression level (typically around 6).
pub fn render_png_rows(
  rows rows: List(BitArray),
  width width: Int,
  height height: Int,
  colour_type colour_type: ColourType,
  bit_depth bit_depth: Int,
  palette palette: Option(List(Rgb)),
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  let data = do_flatten_rows(rows, <<>>)
  render_png_raw_data(
    data:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  )
}

fn render_rows(
  width width: Int,
  height height: Int,
  state state: state,
  plot plot: fn(state, Int, Int) -> #(state, a),
  render render: fn(BitArray, a) -> BitArray,
) -> #(state, List(BitArray)) {
  let #(state, rows) =
    int.range(0, height, #(state, []), fn(acc, y) {
      let #(state, rows) = acc
      let #(state, row) =
        int.range(0, width, #(state, <<>>), fn(acc, x) {
          let #(state, row) = acc
          let #(state, value) = plot(state, x, y)
          let row = render(row, value)
          #(state, row)
        })
      #(state, [row, ..rows])
    })
  #(state, list.reverse(rows))
}

fn simple_render_rows(
  width width: Int,
  height height: Int,
  plot plot: fn(Int, Int) -> a,
  render render: fn(BitArray, a) -> BitArray,
) -> List(BitArray) {
  int.range(0, height, [], fn(rows, y) {
    [int.range(0, width, <<>>, fn(row, x) { render(row, plot(x, y)) }), ..rows]
  })
  |> list.reverse
}

fn max_value(bit_depth: Int) -> Int {
  int.bitwise_shift_left(1, bit_depth) - 1
}

fn render_value(bit_depth: Int) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row, value) { <<row:bits, int.clamp(value, min:, max:):size(bit_depth)>> }
}

/// Create a PNG image with the indexed colour type by
/// iterating over each pixel with some state.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left) along with the current state.
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn render_indexed_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  palette palette: List(Rgb),
  state state: state,
  pixel plot: fn(state, Int, Int) -> #(state, Int),
  compression_level compression_level: Option(Int),
) -> Result(#(state, BitArray), PngRenderError) {
  let render = render_value(bit_depth)
  let #(state, rows) = render_rows(width:, height:, state:, plot:, render:)
  let colour_type = Indexed
  let palette = Some(palette)
  use png <- result.map(render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  ))
  #(state, png)
}

/// Create a PNG image with the indexed colour type by
/// iterating over each pixel.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left).
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn simple_render_indexed_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  palette palette: List(Rgb),
  pixel plot: fn(Int, Int) -> Int,
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  let render = render_value(bit_depth)
  let rows = simple_render_rows(width:, height:, plot:, render:)
  let colour_type = Indexed
  let palette = Some(palette)
  render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  )
}

/// Create a PNG image with the greyscale colour type by
/// iterating over each pixel with some state.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left) along with the current state.
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn render_greyscale_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  state state: state,
  pixel plot: fn(state, Int, Int) -> #(state, Int),
  compression_level compression_level: Option(Int),
) -> Result(#(state, BitArray), PngRenderError) {
  let render = render_value(bit_depth)
  let #(state, rows) = render_rows(width:, height:, state:, plot:, render:)
  let colour_type = Greyscale(False)
  let palette = None
  use png <- result.map(render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  ))
  #(state, png)
}

/// Create a PNG image with the greyscale colour type by
/// iterating over each pixel.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left).
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn simple_render_greyscale_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  pixel plot: fn(Int, Int) -> Int,
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  let render = render_value(bit_depth)
  let rows = simple_render_rows(width:, height:, plot:, render:)
  let colour_type = Greyscale(False)
  let palette = None
  render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  )
}

fn render_va(bit_depth: Int) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row: BitArray, va: Va) {
    <<
      row:bits,
      int.clamp(va.v, min:, max:):size(bit_depth),
      int.clamp(va.a, min:, max:):size(bit_depth),
    >>
  }
}

/// Create a PNG image with the greyscale+alpha colour type by
/// iterating over each pixel with some state.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left) along with the current state.
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn render_transparent_greyscale_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  state state: state,
  pixel plot: fn(state, Int, Int) -> #(state, Va),
  compression_level compression_level: Option(Int),
) -> Result(#(state, BitArray), PngRenderError) {
  let render = render_va(bit_depth)
  let #(state, rows) = render_rows(width:, height:, state:, plot:, render:)
  let colour_type = Greyscale(True)
  let palette = None
  use png <- result.map(render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  ))
  #(state, png)
}

/// Create a PNG image with the greyscale+alpha colour type by
/// iterating over each pixel.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left).
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn simple_render_transparent_greyscale_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  pixel plot: fn(Int, Int) -> Va,
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  let render = render_va(bit_depth)
  let rows = simple_render_rows(width:, height:, plot:, render:)
  let colour_type = Greyscale(True)
  let palette = None
  render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  )
}

fn render_rgb(bit_depth: Int) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row: BitArray, rgb: Rgb) {
    <<
      row:bits,
      int.clamp(rgb.r, min:, max:):size(bit_depth),
      int.clamp(rgb.g, min:, max:):size(bit_depth),
      int.clamp(rgb.b, min:, max:):size(bit_depth),
    >>
  }
}

/// Create a PNG image with the RGB colour type by
/// iterating over each pixel with some state.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left) along with the current state.
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn render_colour_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  state state: state,
  pixel plot: fn(state, Int, Int) -> #(state, Rgb),
  compression_level compression_level: Option(Int),
) -> Result(#(state, BitArray), PngRenderError) {
  let render = render_rgb(bit_depth)
  let #(state, rows) = render_rows(width:, height:, state:, plot:, render:)
  let colour_type = Colour(False)
  let palette = None
  use png <- result.map(render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  ))
  #(state, png)
}

/// Create a PNG image with the RGB colour type by
/// iterating over each pixel.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left).
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn simple_render_colour_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  pixel plot: fn(Int, Int) -> Rgb,
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  let render = render_rgb(bit_depth)
  let rows = simple_render_rows(width:, height:, plot:, render:)
  let colour_type = Colour(False)
  let palette = None
  render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  )
}

fn render_rgba(bit_depth: Int) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row: BitArray, rgba: Rgba) {
    <<
      row:bits,
      int.clamp(rgba.r, min:, max:):size(bit_depth),
      int.clamp(rgba.g, min:, max:):size(bit_depth),
      int.clamp(rgba.b, min:, max:):size(bit_depth),
      int.clamp(rgba.a, min:, max:):size(bit_depth),
    >>
  }
}

/// Create a PNG image with the RGBA colour type by
/// iterating over each pixel with some state.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left) along with the current state.
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn render_transparent_colour_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  state state: state,
  pixel plot: fn(state, Int, Int) -> #(state, Rgba),
  compression_level compression_level: Option(Int),
) -> Result(#(state, BitArray), PngRenderError) {
  let render = render_rgba(bit_depth)
  let #(state, rows) = render_rows(width:, height:, state:, plot:, render:)
  let colour_type = Colour(True)
  let palette = None
  use png <- result.map(render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  ))
  #(state, png)
}

/// Create a PNG image with the RGBA colour type by
/// iterating over each pixel.
/// 
/// The callback gets the X and Y position of the pixel
/// (where 0,0 is the top-left).
/// 
/// Rendering starts at the top and goes over each row,
/// left to right, top to bottom.
/// 
/// Values outside the range supported by the provided
/// bit depth will be clamped between 0 and the maximum value.
pub fn simple_render_transparent_colour_png(
  width width: Int,
  height height: Int,
  bit_depth bit_depth: Int,
  pixel plot: fn(Int, Int) -> Rgba,
  compression_level compression_level: Option(Int),
) -> Result(BitArray, PngRenderError) {
  let render = render_rgba(bit_depth)
  let rows = simple_render_rows(width:, height:, plot:, render:)
  let colour_type = Colour(True)
  let palette = None
  render_png_rows(
    rows:,
    width:,
    height:,
    colour_type:,
    bit_depth:,
    palette:,
    compression_level:,
  )
}

type RawChunkData {
  RawChunkData(tag: BitArray, data: BitArray, rest: BitArray)
}

fn parse_chunk(data: BitArray) -> Result(RawChunkData, PngParseError) {
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

fn parse_signature(data: BitArray) -> Result(BitArray, PngParseError) {
  case data {
    <<137, 80, 78, 71, 13, 10, 26, 10, rest:bytes>> -> Ok(rest)
    _ -> Error(InvalidSignature)
  }
}

fn parse_header(header_data: BitArray) -> Result(PngMetadata, PngParseError) {
  case header_data {
    <<
      width:32,
      height:32,
      bit_depth,
      colour_type,
      compression_method,
      filter_method,
      interlace_method,
    >> -> {
      use colour_type <- result.try(case colour_type {
        0 -> Ok(Greyscale(False))
        2 -> Ok(Colour(False))
        3 -> Ok(Indexed)
        4 -> Ok(Greyscale(True))
        6 -> Ok(Colour(True))
        _ -> Error(InvalidColourType)
      })
      use _ <- result.try(case colour_type, bit_depth {
        _, 8
        | Indexed, 1
        | Indexed, 2
        | Indexed, 4
        | Greyscale(False), 1
        | Greyscale(False), 2
        | Greyscale(False), 4
        | Greyscale(_), 16
        | Colour(_), 16
        -> Ok(Nil)
        _, _ -> Error(InvalidParsedBitDepth)
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
      Ok(PngMetadata(width:, height:, colour_type:, bit_depth:))
    }
    _ -> Error(InvalidChunkData)
  }
}

/// Parse only the metadata chunk at the start of the PNG.
pub fn parse_metadata(data: BitArray) -> Result(PngMetadata, PngParseError) {
  use data <- result.try(parse_signature(data))
  use RawChunkData(tag:, data:, rest: _) <- result.try(parse_chunk(data))
  use <- bool.guard(tag != <<"IHDR">>, Error(MissingHeaderChunk))
  parse_header(data)
}

type PngDataState {
  PngDataState(
    palette: Option(List(Rgb)),
    image_data: List(BitArray),
    other_data: List(#(BitArray, BitArray)),
  )
}

fn do_parse_palette(
  data: BitArray,
  palette: List(Rgb),
) -> Result(List(Rgb), Nil) {
  case data {
    <<>> -> Ok(list.reverse(palette))
    <<r, g, b, data:bits>> ->
      do_parse_palette(data, [Rgb(r:, g:, b:), ..palette])
    _ -> Error(Nil)
  }
}

fn do_parse_image_data(
  data: BitArray,
  state: PngDataState,
) -> Result(PngDataState, PngParseError) {
  case data {
    <<>> ->
      Ok(
        PngDataState(
          ..state,
          image_data: list.reverse(state.image_data),
          other_data: list.reverse(state.other_data),
        ),
      )
    data ->
      case parse_chunk(data) {
        Ok(RawChunkData(tag:, data:, rest:)) ->
          case tag {
            <<"PLTE">> ->
              case do_parse_palette(data, []) {
                Ok(palette) ->
                  do_parse_image_data(
                    rest,
                    PngDataState(..state, palette: Some(palette)),
                  )
                Error(Nil) -> Error(InvalidPalette)
              }
            <<"IDAT">> ->
              do_parse_image_data(
                rest,
                PngDataState(..state, image_data: [data, ..state.image_data]),
              )
            <<"IEND">> -> Ok(state)
            _ ->
              do_parse_image_data(
                rest,
                PngDataState(..state, other_data: [
                  #(tag, data),
                  ..state.other_data
                ]),
              )
          }
        Error(e) -> Error(e)
      }
  }
}

fn do_add_bytewise(xs: BitArray, ys: BitArray, acc: BitArray) -> BitArray {
  case xs, ys {
    <<x, xs:bits>>, <<y, ys:bits>> ->
      do_add_bytewise(xs, ys, <<acc:bits, { x + y }>>)
    _, _ -> acc
  }
}

// Only used when filtering, not unfiltering
// fn do_subtract_bytewise(xs: BitArray, ys: BitArray, acc: BitArray) -> BitArray {
//   case xs, ys {
//     <<x, xs:bits>>, <<y, ys:bits>> ->
//       do_subtract_bytewise(xs, ys, <<acc:bits, { x - y }>>)
//     _, _ -> acc
//   }
// }

fn do_average_bytewise(xs: BitArray, ys: BitArray, acc: BitArray) -> BitArray {
  case xs, ys {
    <<x, xs:bits>>, <<y, ys:bits>> ->
      do_average_bytewise(xs, ys, <<acc:bits, { { x + y } / 2 }>>)
    _, _ -> acc
  }
}

fn do_paeth_bytewise(
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

fn offset_row(row: BitArray, bpp: Int) -> BitArray {
  <<0:unit(8)-size(bpp), row:bits>>
}

fn previous_row(rows: List(BitArray), row_size: Int) -> BitArray {
  case rows {
    [] -> <<0:unit(8)-size(row_size)>>
    [prev, ..] -> prev
  }
}

fn do_parse_image_rows(
  data: BitArray,
  row_size: Int,
  bpp: Int,
  rows: List(BitArray),
) -> Result(List(BitArray), PngParseError) {
  case data {
    <<>> -> Ok(list.reverse(rows))
    <<filter_type, row:bytes-size(row_size), data:bits>> ->
      case filter_type {
        0 -> do_parse_image_rows(data, row_size, bpp, [row, ..rows])
        1 ->
          do_parse_image_rows(data, row_size, bpp, [
            do_add_bytewise(row, offset_row(row, bpp), <<>>),
            ..rows
          ])
        2 ->
          do_parse_image_rows(data, row_size, bpp, [
            do_add_bytewise(row, previous_row(rows, row_size), <<>>),
            ..rows
          ])
        3 ->
          do_parse_image_rows(data, row_size, bpp, [
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
          do_parse_image_rows(data, row_size, bpp, [
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

/// Parse the PNG into a list of bit arrays representing each row of the image.
pub fn parse_png(data: BitArray) -> Result(PngImage, PngParseError) {
  use data <- result.try(parse_signature(data))
  use RawChunkData(tag:, data:, rest:) <- result.try(parse_chunk(data))
  use <- bool.guard(tag != <<"IHDR">>, return: Error(MissingHeaderChunk))
  use metadata <- result.try(parse_header(data))
  use PngDataState(palette:, image_data:, other_data:) <- result.try(
    do_parse_image_data(
      rest,
      PngDataState(palette: None, image_data: [], other_data: []),
    ),
  )
  use image_data <- result.try(
    image_data
    |> bit_array.concat
    |> gzlib.uncompress
    |> result.replace_error(InvalidDeflateData),
  )
  let bpp =
    case metadata.colour_type {
      Indexed -> 1
      Greyscale(False) -> 1
      Greyscale(True) -> 2
      Colour(False) -> 3
      Colour(True) -> 4
    }
    * metadata.bit_depth
  let row_size = { metadata.width * bpp + 7 } / 8
  let bpp = { bpp + 7 } / 8
  use image_data <- result.try(
    do_parse_image_rows(image_data, row_size, bpp, []),
  )
  Ok(PngImage(metadata:, palette:, image_data:, other_data:))
}

/// Returns the pixel at a specific x,y coordinate in the image (where 0,0 is the top left).
/// 
/// Returns an error if no pixel data was found at the given location.
pub fn read_pixel_at(
  png: PngImage,
  x x: Int,
  y y: Int,
) -> Result(ColourData, Nil) {
  let PngImage(
    metadata: PngMetadata(width:, height:, colour_type:, bit_depth:),
    image_data:,
    ..,
  ) = png
  let row = case y {
    y if y < 0 -> height + y
    y -> y
  }
  let column = case x {
    x if x < 0 -> width + x
    x -> x
  }
  use row <- result.try(
    case row {
      row if row < 0 -> list.drop(list.reverse(image_data), -row)
      row -> list.drop(image_data, row)
    }
    |> list.first,
  )
  case colour_type, row {
    Indexed, <<_:bytes-size(column * bit_depth), i:size(bit_depth), _:bits>> ->
      Ok(IndexedData(i:))
    Greyscale(False),
      <<_:bytes-size(column * bit_depth), v:size(bit_depth), _:bits>>
    -> Ok(GreyscaleData(v:, a: None))
    Greyscale(True),
      <<
        _:bytes-size(column * bit_depth),
        v:size(bit_depth),
        a:size(bit_depth),
        _:bits,
      >>
    -> Ok(GreyscaleData(v:, a: Some(a)))
    Colour(False),
      <<
        _:bytes-size(column * bit_depth),
        r:size(bit_depth),
        g:size(bit_depth),
        b:size(bit_depth),
        _:bits,
      >>
    -> Ok(ColourData(r:, g:, b:, a: None))
    Colour(True),
      <<
        _:bytes-size(column * bit_depth),
        r:size(bit_depth),
        g:size(bit_depth),
        b:size(bit_depth),
        a:size(bit_depth),
        _:bits,
      >>
    -> Ok(ColourData(r:, g:, b:, a: Some(a)))
    _, _ -> Error(Nil)
  }
}

fn do_read_values(row: BitArray, bit_depth: Int, acc: List(Int)) -> List(Int) {
  case row {
    <<v:size(bit_depth), row:bits>> ->
      do_read_values(row, bit_depth, [v, ..acc])
    _ -> list.reverse(acc)
  }
}

/// Read a single row of pixels from a PNG image
/// with an indexed colour type.
/// 
/// Returns an error if the provided bit depth is
/// invalid for this colour type.
pub fn read_indexed_pixel_row(
  row: BitArray,
  bit_depth: Int,
) -> Result(List(Int), Nil) {
  use <- bool.guard(
    case bit_depth {
      1 | 2 | 4 | 8 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  do_read_values(row, bit_depth, []) |> Ok
}

/// Fold over all the pixels in a parsed PNG image
/// with an indexed colour type.
/// 
/// The callback gets the X and Y position of the pixel,
/// (where 0,0 is the top-left) along with the indexed pixel value.
/// 
/// The fold starts at the top and goes over each
/// row, left to right, top to bottom.
/// 
/// Returns an error if the provided PNG is not the correct
/// colour type or is an invalid bit depth for this colour type.
pub fn fold_indexed_pixels(
  png: PngImage,
  state state: state,
  with fun: fn(state, Int, Int, Int) -> state,
) -> Result(state, Nil) {
  use <- bool.guard(png.metadata.colour_type != Indexed, return: Error(Nil))
  use <- bool.guard(
    case png.metadata.bit_depth {
      1 | 2 | 4 | 8 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  list.index_fold(png.image_data, state, fn(state, row, y) {
    list.index_fold(
      do_read_values(row, png.metadata.bit_depth, []),
      state,
      fn(state, v, x) { fun(state, x, y, v) },
    )
  })
  |> Ok
}

/// Read a single row of pixels from a PNG image
/// with a greyscale colour type.
/// 
/// Returns an error if the provided bit depth is
/// invalid for this colour type.
pub fn read_greyscale_pixel_row(
  row: BitArray,
  bit_depth: Int,
) -> Result(List(Int), Nil) {
  use <- bool.guard(
    case bit_depth {
      1 | 2 | 4 | 8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  do_read_values(row, bit_depth, []) |> Ok
}

/// Fold over all the pixels in a parsed PNG image
/// with a greyscale colour type.
/// 
/// The callback gets the X and Y position of the pixel,
/// (where 0,0 is the top-left) along with the greyscale pixel value.
/// 
/// The fold starts at the top and goes over each
/// row, left to right, top to bottom.
/// 
/// Returns an error if the provided PNG is not the correct
/// colour type or is an invalid bit depth for this colour type.
pub fn fold_greyscale_pixels(
  png: PngImage,
  state state: state,
  with fun: fn(state, Int, Int, Int) -> state,
) -> Result(state, Nil) {
  use <- bool.guard(
    png.metadata.colour_type != Greyscale(False),
    return: Error(Nil),
  )
  use <- bool.guard(
    case png.metadata.bit_depth {
      1 | 2 | 4 | 8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  list.index_fold(png.image_data, state, fn(state, row, y) {
    list.index_fold(
      do_read_values(row, png.metadata.bit_depth, []),
      state,
      fn(state, v, x) { fun(state, x, y, v) },
    )
  })
  |> Ok
}

fn do_read_va(row: BitArray, bit_depth: Int, acc: List(Va)) -> List(Va) {
  case row {
    <<v:size(bit_depth), a:size(bit_depth), row:bits>> ->
      do_read_va(row, bit_depth, [Va(v:, a:), ..acc])
    _ -> list.reverse(acc)
  }
}

/// Read a single row of pixels from a PNG image
/// with a greyscale+alpha colour type.
/// 
/// Returns an error if the provided bit depth is
/// invalid for this colour type.
pub fn read_transparent_greyscale_pixel_row(
  row: BitArray,
  bit_depth: Int,
) -> Result(List(Va), Nil) {
  use <- bool.guard(
    case bit_depth {
      8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  do_read_va(row, bit_depth, []) |> Ok
}

/// Fold over all the pixels in a parsed PNG image
/// with a greyscale+alpha colour type.
/// 
/// The callback gets the X and Y position of the pixel,
/// (where 0,0 is the top-left) along with the greyscale+alpha pixel value.
/// 
/// The fold starts at the top and goes over each
/// row, left to right, top to bottom.
/// 
/// Returns an error if the provided PNG is not the correct
/// colour type or is an invalid bit depth for this colour type.
pub fn fold_transparent_greyscale_pixels(
  png: PngImage,
  state state: state,
  with fun: fn(state, Int, Int, Va) -> state,
) -> Result(state, Nil) {
  use <- bool.guard(
    png.metadata.colour_type != Greyscale(True),
    return: Error(Nil),
  )
  use <- bool.guard(
    case png.metadata.bit_depth {
      8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  list.index_fold(png.image_data, state, fn(state, row, y) {
    list.index_fold(
      do_read_va(row, png.metadata.bit_depth, []),
      state,
      fn(state, va, x) { fun(state, x, y, va) },
    )
  })
  |> Ok
}

fn do_read_rgb(row: BitArray, bit_depth: Int, acc: List(Rgb)) -> List(Rgb) {
  case row {
    <<r:size(bit_depth), g:size(bit_depth), b:size(bit_depth), row:bits>> ->
      do_read_rgb(row, bit_depth, [Rgb(r:, g:, b:), ..acc])
    _ -> list.reverse(acc)
  }
}

/// Read a single row of pixels from a PNG image
/// with an RGB colour type.
/// 
/// Returns an error if the provided bit depth is
/// invalid for this colour type.
pub fn read_colour_pixel_row(
  row: BitArray,
  bit_depth: Int,
) -> Result(List(Rgb), Nil) {
  use <- bool.guard(
    case bit_depth {
      8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  do_read_rgb(row, bit_depth, []) |> Ok
}

/// Fold over all the pixels in a parsed PNG image
/// with an RGB colour type.
/// 
/// The callback gets the X and Y position of the pixel,
/// (where 0,0 is the top-left) along with the RGB pixel value.
/// 
/// The fold starts at the top and goes over each
/// row, left to right, top to bottom.
/// 
/// Returns an error if the provided PNG is not the correct
/// colour type or is an invalid bit depth for this colour type.
pub fn fold_colour_pixels(
  png: PngImage,
  state state: state,
  with fun: fn(state, Int, Int, Rgb) -> state,
) -> Result(state, Nil) {
  use <- bool.guard(
    png.metadata.colour_type != Colour(False),
    return: Error(Nil),
  )
  use <- bool.guard(
    case png.metadata.bit_depth {
      8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  list.index_fold(png.image_data, state, fn(state, row, y) {
    list.index_fold(
      do_read_rgb(row, png.metadata.bit_depth, []),
      state,
      fn(state, rgb, x) { fun(state, x, y, rgb) },
    )
  })
  |> Ok
}

fn do_read_rgba(row: BitArray, bit_depth: Int, acc: List(Rgba)) -> List(Rgba) {
  case row {
    <<
      r:size(bit_depth),
      g:size(bit_depth),
      b:size(bit_depth),
      a:size(bit_depth),
      row:bits,
    >> -> do_read_rgba(row, bit_depth, [Rgba(r:, g:, b:, a:), ..acc])
    _ -> list.reverse(acc)
  }
}

/// Read a single row of pixels from a PNG image
/// with an RGBA colour type.
/// 
/// Returns an error if the provided bit depth is
/// invalid for this colour type.
pub fn read_transparent_colour_pixel_row(
  row: BitArray,
  bit_depth: Int,
) -> Result(List(Rgba), Nil) {
  use <- bool.guard(
    case bit_depth {
      8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  do_read_rgba(row, bit_depth, []) |> Ok
}

/// Fold over all the pixels in a parsed PNG image
/// with an RGBA colour type.
/// 
/// The callback gets the X and Y position of the pixel,
/// (where 0,0 is the top-left) along with the RGBA pixel value.
/// 
/// The fold starts at the top and goes over each
/// row, left to right, top to bottom.
/// 
/// Returns an error if the provided PNG is not the correct
/// colour type or is an invalid bit depth for this colour type.
pub fn fold_transparent_colour_pixels(
  png: PngImage,
  state state: state,
  with fun: fn(state, Int, Int, Rgba) -> state,
) -> Result(state, Nil) {
  use <- bool.guard(
    png.metadata.colour_type != Colour(True),
    return: Error(Nil),
  )
  use <- bool.guard(
    case png.metadata.bit_depth {
      8 | 16 -> False
      _ -> True
    },
    return: Error(Nil),
  )
  list.index_fold(png.image_data, state, fn(state, row, y) {
    list.index_fold(
      do_read_rgba(row, png.metadata.bit_depth, []),
      state,
      fn(state, rgba, x) { fun(state, x, y, rgba) },
    )
  })
  |> Ok
}
