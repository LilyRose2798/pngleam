import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gzlib
import pngleam/parse
import pngleam/read
import pngleam/render

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
  /// The image uses a fixed colour palette, and each pixel stores the index into that palette.
  Indexed
  /// The image can only represent grey values.
  Greyscale(alpha: Bool)
  /// The image can represent full colour values.
  Colour(alpha: Bool)
}

/// A representation of any possible colour value that
/// can be contained within a PNG image.
pub type ColourData {
  /// The pixel data for an indexed image, representing the index in the colour palette of that image.
  IndexedData(i: Int)
  /// The pixel data for a greyscale value, optionally with an alpha value if the image is of that colour type.
  GreyscaleData(v: Int, a: Option(Int))
  /// The pixel data for a full colour RGB value, optionally with an alpha value if the image is of that colour type.
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
  /// The data provided was not byte-aligned.
  UnalignedData
  /// The bit depth provided was not valid for the colour type being used.
  InvalidBitDepth
  /// The compression level was not within the supported range (0-9)
  InvalidCompressionLevel
}

/// The possible error states when parsing a PNG image.
pub type PngParseError {
  /// The signature was not that of a PNG image but of a different file type.
  InvalidSignature
  /// The checksum calculated for a chunk in the PNG did not match the one provided for that chunk.
  ChecksumMismatch
  /// The image was missing a header (IHDR) chunk.
  MissingHeaderChunk
  /// The image was missing the IEND chunk.
  MissingIENDChunk
  /// A chunk in the image was not in the correct format.
  InvalidChunkData
  /// The colour type in the image was not one of the valid types (0, 2, 3, 4, and 6).
  InvalidColourType
  /// The bit depth in the image was not valid for the colour type being used.
  InvalidParsedBitDepth
  /// The compression type in the image was not one of the valid types (0).
  InvalidCompressionType
  /// The filter method in the image was not one of the valid types (0).
  InvalidFilterMethod
  /// The interlace method in the image was not one of the valid type (0 and 1).
  InvalidInterlaceMethod
  /// The interlace method used by the image is not supported by the parser. Only 0 (no interlacing) is supported.
  UnsupportedInterlaceMethod
  /// The palette data was invalid.
  InvalidPalette
  /// The row filter type was not one of the valid values (0, 1, 2, 3, and 4).
  InvalidRowFilterType
  /// The row data was invalid.
  InvalidRowData
  /// The image data was not valid deflate data (i.e. missing zlib headers).
  InvalidDeflateData
}

fn map_parse_error(err: parse.Error) -> PngParseError {
  case err {
    parse.InvalidSignature -> InvalidSignature
    parse.ChecksumMismatch -> ChecksumMismatch
    parse.MissingHeaderChunk -> MissingHeaderChunk
    parse.MissingIENDChunk -> MissingIENDChunk
    parse.InvalidChunkData -> InvalidChunkData
    parse.InvalidColourType -> InvalidColourType
    parse.InvalidParsedBitDepth -> InvalidParsedBitDepth
    parse.InvalidCompressionType -> InvalidCompressionType
    parse.InvalidFilterMethod -> InvalidFilterMethod
    parse.InvalidInterlaceMethod -> InvalidInterlaceMethod
    parse.UnsupportedInterlaceMethod -> UnsupportedInterlaceMethod
    parse.InvalidPalette -> InvalidPalette
    parse.InvalidRowFilterType -> InvalidRowFilterType
    parse.InvalidRowData -> InvalidRowData
    parse.InvalidDeflateData -> InvalidDeflateData
  }
}

fn map_render_error(err: render.Error) -> PngRenderError {
  case err {
    render.UnalignedData -> UnalignedData
    render.InvalidBitDepth -> InvalidBitDepth
    render.InvalidCompressionLevel -> InvalidCompressionLevel
  }
}

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
    render.chunk(<<"IHDR">>, <<
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
    >>)
    |> result.map_error(map_render_error),
  )
  use plte <- result.try(case palette {
    Some(palette) ->
      render.chunk(
        <<"PLTE">>,
        list.fold(
          palette,
          <<>>,
          render.rgb(8, fn(rgb: Rgb) { #(rgb.r, rgb.g, rgb.b) }),
        ),
      )
      |> result.map_error(map_render_error)
    None -> Ok(<<>>)
  })
  use compressed <- result.try(
    compress(data)
    |> result.replace_error(UnalignedData),
  )
  use idats <- result.try(
    render.do_chunk_bits(compressed, [])
    |> list.try_map(fn(chunk_data) {
      render.chunk(<<"IDAT">>, chunk_data)
      |> result.map_error(map_render_error)
    })
    |> result.map(bit_array.concat),
  )
  use iend <- result.try(
    render.chunk(<<"IEND">>, <<>>)
    |> result.map_error(map_render_error),
  )
  Ok(<<
    render.signature:bits,
    ihdr:bits,
    plte:bits,
    idats:bits,
    iend:bits,
  >>)
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
  let data = render.do_flatten_rows(rows, <<>>)
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

/// Create a PNG image with the indexed colour type by
/// iterating over each pixel with some state.
/// 
/// An indexed image is one where a colour palette is specified
/// for the image, and the pixel data just references the index
/// within that palette that each pixel should be.
/// 
/// Each pixel value should be a number between 0 and one less
/// than the length of the colour palette.
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
  let render_val = render.value(bit_depth)
  let #(state, rows) =
    render.rows(width:, height:, state:, plot:, render: render_val)
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
/// An indexed image is one where a colour palette is specified
/// for the image, and the pixel data just references the index
/// within that palette that each pixel should be.
/// 
/// Each pixel value should be a number between 0 and one less
/// than the length of the colour palette.
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
  let render_val = render.value(bit_depth)
  let rows =
    render.simple_render_rows(width:, height:, plot:, render: render_val)
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
  let render_val = render.value(bit_depth)
  let #(state, rows) =
    render.rows(width:, height:, state:, plot:, render: render_val)
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
  let render_val = render.value(bit_depth)
  let rows =
    render.simple_render_rows(width:, height:, plot:, render: render_val)
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
  let render_va = render.va(bit_depth, fn(va: Va) { #(va.v, va.a) })
  let #(state, rows) =
    render.rows(width:, height:, state:, plot:, render: render_va)
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
  let render_va = render.va(bit_depth, fn(va: Va) { #(va.v, va.a) })
  let rows =
    render.simple_render_rows(width:, height:, plot:, render: render_va)
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
  let render_rgb =
    render.rgb(bit_depth, fn(rgb: Rgb) { #(rgb.r, rgb.g, rgb.b) })
  let #(state, rows) =
    render.rows(width:, height:, state:, plot:, render: render_rgb)
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
  let render_rgb =
    render.rgb(bit_depth, fn(rgb: Rgb) { #(rgb.r, rgb.g, rgb.b) })
  let rows =
    render.simple_render_rows(width:, height:, plot:, render: render_rgb)
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
  let render_rgba =
    render.rgba(bit_depth, fn(rgba: Rgba) { #(rgba.r, rgba.g, rgba.b, rgba.a) })
  let #(state, rows) =
    render.rows(width:, height:, state:, plot:, render: render_rgba)
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
  let render_rgba =
    render.rgba(bit_depth, fn(rgba: Rgba) { #(rgba.r, rgba.g, rgba.b, rgba.a) })
  let rows =
    render.simple_render_rows(width:, height:, plot:, render: render_rgba)
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

/// Parse only the metadata chunk at the start of the PNG.
pub fn parse_metadata(data: BitArray) -> Result(PngMetadata, PngParseError) {
  use data <- result.try(
    parse.signature(data) |> result.map_error(map_parse_error),
  )
  use parse.RawChunkData(tag:, data:, rest: _) <- result.try(
    parse.chunk(data) |> result.map_error(map_parse_error),
  )
  use <- bool.guard(tag != <<"IHDR">>, return: Error(MissingHeaderChunk))
  use parse.ParsedHeader(width:, height:, colour_type_code:, bit_depth:) <- result.try(
    parse.header(data) |> result.map_error(map_parse_error),
  )
  let colour_type = case colour_type_code {
    0 -> Greyscale(False)
    2 -> Colour(False)
    3 -> Indexed
    4 -> Greyscale(True)
    6 -> Colour(True)
    _ -> panic
  }
  Ok(PngMetadata(width:, height:, colour_type:, bit_depth:))
}

/// Parse the PNG into a list of bit arrays representing each row of the image.
pub fn parse_png(data: BitArray) -> Result(PngImage, PngParseError) {
  use data <- result.try(
    parse.signature(data) |> result.map_error(map_parse_error),
  )
  use parse.RawChunkData(tag:, data:, rest:) <- result.try(
    parse.chunk(data) |> result.map_error(map_parse_error),
  )
  use <- bool.guard(tag != <<"IHDR">>, return: Error(MissingHeaderChunk))
  use parse.ParsedHeader(width:, height:, colour_type_code:, bit_depth:) <- result.try(
    parse.header(data) |> result.map_error(map_parse_error),
  )
  let colour_type = case colour_type_code {
    0 -> Greyscale(False)
    2 -> Colour(False)
    3 -> Indexed
    4 -> Greyscale(True)
    6 -> Colour(True)
    _ -> panic
  }
  use parse.PngDataState(palette:, image_data:, other_data:) <- result.try(
    parse.do_image_data(
      rest,
      parse.PngDataState(palette: None, image_data: [], other_data: []),
      fn(r, g, b) { Rgb(r:, g:, b:) },
    )
    |> result.map_error(map_parse_error),
  )
  use image_data <- result.try(
    image_data
    |> bit_array.concat
    |> gzlib.uncompress
    |> result.replace_error(InvalidDeflateData),
  )
  let bpp =
    case colour_type {
      Indexed -> 1
      Greyscale(False) -> 1
      Greyscale(True) -> 2
      Colour(False) -> 3
      Colour(True) -> 4
    }
    * bit_depth
  let row_size = { width * bpp + 7 } / 8
  let bpp = { bpp + 7 } / 8
  use image_data <- result.try(
    parse.do_image_rows(image_data, row_size, bpp, [])
    |> result.map_error(map_parse_error),
  )
  let metadata = PngMetadata(width:, height:, colour_type:, bit_depth:)
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

/// Read a single row of pixels from a PNG image
/// with an indexed colour type.
/// 
/// An indexed image is one where a colour palette is specified
/// for the image, and the pixel data just references the index
/// within that palette.
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
  read.do_read_values(row, bit_depth, []) |> Ok
}

/// Fold over all the pixels in a parsed PNG image
/// with an indexed colour type.
/// 
/// An indexed image is one where a colour palette is specified
/// for the image, and the pixel data just references the index
/// within that palette.
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
      read.do_read_values(row, png.metadata.bit_depth, []),
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
  read.do_read_values(row, bit_depth, []) |> Ok
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
      read.do_read_values(row, png.metadata.bit_depth, []),
      state,
      fn(state, v, x) { fun(state, x, y, v) },
    )
  })
  |> Ok
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
  read.do_read_va(row, bit_depth, [], fn(v, a) { Va(v:, a:) }) |> Ok
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
      read.do_read_va(row, png.metadata.bit_depth, [], fn(v, a) { Va(v:, a:) }),
      state,
      fn(state, va, x) { fun(state, x, y, va) },
    )
  })
  |> Ok
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
  read.do_read_rgb(row, bit_depth, [], fn(r, g, b) { Rgb(r:, g:, b:) }) |> Ok
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
      read.do_read_rgb(row, png.metadata.bit_depth, [], fn(r, g, b) {
        Rgb(r:, g:, b:)
      }),
      state,
      fn(state, rgb, x) { fun(state, x, y, rgb) },
    )
  })
  |> Ok
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
  read.do_read_rgba(row, bit_depth, [], fn(r, g, b, a) { Rgba(r:, g:, b:, a:) })
  |> Ok
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
      read.do_read_rgba(row, png.metadata.bit_depth, [], fn(r, g, b, a) {
        Rgba(r:, g:, b:, a:)
      }),
      state,
      fn(state, rgba, x) { fun(state, x, y, rgba) },
    )
  })
  |> Ok
}
