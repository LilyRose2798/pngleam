import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import pngleam
import simplifile

fn find_project_root(path: String) -> String {
  let toml = path <> "/gleam.toml"
  case simplifile.is_file(toml) {
    Ok(True) -> path
    _ -> find_project_root(path <> "/..")
  }
}

fn get_test_data_dir() -> String {
  let assert Ok(cwd) = simplifile.current_directory()
  find_project_root(cwd) <> "/test_data"
}

/// test that all valid PNG files parse successfully and metadata matches
pub fn parse_all_valid_pngs_test() {
  let test_data_dir = get_test_data_dir()
  let assert Ok(test_dir) = simplifile.read_directory(test_data_dir)

  test_dir
  |> list.filter(fn(name) {
    string.ends_with(name, ".png") && !string.starts_with(name, "x")
  })
  |> list.each(fn(file_name) {
    let assert Ok(data) =
      simplifile.read_bits(test_data_dir <> "/" <> file_name)
    let assert Ok(png) = pngleam.parse_png(data)
    let assert Ok(metadata) = pngleam.parse_metadata(data)

    let assert True = png.metadata.width > 0
    let assert True = png.metadata.height > 0
    let assert True = png.metadata == metadata
    let assert True = list.length(png.image_data) == png.metadata.height
  })
}

/// test that Adam7 interlaced PNGs produce the exact same decoded image data as non-interlaced PNGs
pub fn interlaced_matches_non_interlaced_test() {
  let test_data_dir = get_test_data_dir()
  let assert Ok(test_dir) = simplifile.read_directory(test_data_dir)

  // find all size-test interlaced files (s*i*) which have identical pixel data to s*n*
  let interlaced_files =
    test_dir
    |> list.filter(fn(name) {
      string.ends_with(name, ".png")
      && string.starts_with(name, "s")
      && string.contains(name, "i3p")
    })

  interlaced_files
  |> list.each(fn(interlaced_name) {
    let non_interlaced_name = case string.starts_with(interlaced_name, "basi") {
      True -> "basn" <> string.drop_start(interlaced_name, 4)
      False -> string.replace(interlaced_name, "i3p", "n3p")
    }

    case simplifile.is_file(test_data_dir <> "/" <> non_interlaced_name) {
      Ok(True) -> {
        let assert Ok(interlaced_bytes) =
          simplifile.read_bits(test_data_dir <> "/" <> interlaced_name)
        let assert Ok(non_interlaced_bytes) =
          simplifile.read_bits(test_data_dir <> "/" <> non_interlaced_name)

        let assert Ok(interlaced_png) = pngleam.parse_png(interlaced_bytes)
        let assert Ok(non_interlaced_png) =
          pngleam.parse_png(non_interlaced_bytes)

        // metadata check
        let assert True =
          interlaced_png.metadata.width == non_interlaced_png.metadata.width
        let assert True =
          interlaced_png.metadata.height == non_interlaced_png.metadata.height
        let assert 1 = interlaced_png.metadata.interlace_method
        let assert 0 = non_interlaced_png.metadata.interlace_method

        // pixel-perfect image_data comparison
        let assert True =
          interlaced_png.image_data == non_interlaced_png.image_data

        // pixel accessor check at (0,0)
        let assert Ok(p1) = pngleam.read_pixel_at(interlaced_png, 0, 0)
        let assert Ok(p2) = pngleam.read_pixel_at(non_interlaced_png, 0, 0)
        let assert True = p1 == p2
      }
      _ -> True
    }
  })
}

/// test that corrupted PNG files with invalid signatures or missing IDAT chunks return an Error.
pub fn corrupted_pngs_fail_test() {
  let test_data_dir = get_test_data_dir()
  let assert Ok(test_dir) = simplifile.read_directory(test_data_dir)

  test_dir
  |> list.filter(fn(name) {
    string.ends_with(name, ".png") && string.starts_with(name, "x")
  })
  |> list.each(fn(file_name) {
    let assert Ok(data) =
      simplifile.read_bits(test_data_dir <> "/" <> file_name)
    let assert Error(_) = pngleam.parse_png(data)
  })
}

/// test pixel reading and folding on sample PNGs.
pub fn pixel_reading_and_folding_test() {
  let test_data_dir = get_test_data_dir()
  let assert Ok(data) = simplifile.read_bits(test_data_dir <> "/basn2c08.png")
  let assert Ok(png) = pngleam.parse_png(data)

  // test read_pixel_at
  let assert Ok(pixel) = pngleam.read_pixel_at(png, 0, 0)
  case pixel {
    pngleam.ColourData(r:, g:, b:, a: None) -> {
      let assert True = r >= 0 && g >= 0 && b >= 0
    }
    _ -> panic
  }

  // test out-of-bounds pixel reading returns Error
  let assert Error(Nil) = pngleam.read_pixel_at(png, 9999, 9999)

  // test fold_colour_pixels
  let assert Ok(pixel_count) =
    pngleam.fold_colour_pixels(png, 0, fn(acc, _x, _y, _color) { acc + 1 })
  let assert True = pixel_count == png.metadata.width * png.metadata.height
}

pub fn missing_iend_chunk_test() {
  let test_data_dir = get_test_data_dir()
  // read a valid PNG (basn0g01.png is 164 bytes)
  let assert Ok(data) = simplifile.read_bits(test_data_dir <> "/basn0g01.png")

  // the IEND chunk is 12 bytes long. We slice it off to trigger MissingIENDChunk.
  let len = bit_array.byte_size(data)
  let len_without_iend = len - 12
  let assert <<data_without_iend:bytes-size(len_without_iend), _rest:bytes>> =
    data

  let assert Error(pngleam.MissingIENDChunk) =
    pngleam.parse_png(data_without_iend)
}

pub fn other_data_order_test() {
  let test_data_dir = get_test_data_dir()
  // ct1n0g04.png contains a gAMA chunk followed by several tEXt chunks.
  let assert Ok(data) = simplifile.read_bits(test_data_dir <> "/ct1n0g04.png")
  let assert Ok(png) = pngleam.parse_png(data)

  // without list.reverse on other_data during parsing, the first element would be tEXt.
  let assert [#(<<"gAMA">>, _), ..] = png.other_data
}

pub fn roundtrip_encode_decode_test() {
  let test_data_dir = get_test_data_dir()
  let assert Ok(test_dir) = simplifile.read_directory(test_data_dir)

  test_dir
  |> list.filter(fn(name) {
    string.ends_with(name, ".png") && !string.starts_with(name, "x")
  })
  |> list.each(fn(file_name) {
    let assert Ok(data) =
      simplifile.read_bits(test_data_dir <> "/" <> file_name)
    let assert Ok(png) = pngleam.parse_png(data)

    // we expect the encoder to use interlace method 0
    let assert Ok(encoded_data) =
      pngleam.render_png_rows(
        rows: png.image_data,
        width: png.metadata.width,
        height: png.metadata.height,
        colour_type: png.metadata.colour_type,
        bit_depth: png.metadata.bit_depth,
        palette: png.palette,
        compression_level: None,
      )

    let assert Ok(re_parsed_png) = pngleam.parse_png(encoded_data)

    // validate everything matches
    let assert True = re_parsed_png.metadata.width == png.metadata.width
    let assert True = re_parsed_png.metadata.height == png.metadata.height
    let assert True =
      re_parsed_png.metadata.colour_type == png.metadata.colour_type
    let assert True = re_parsed_png.metadata.bit_depth == png.metadata.bit_depth
    let assert True = re_parsed_png.image_data == png.image_data
  })
}

pub fn main() {
  gleeunit.main()
}
