import gleam/dict
import gleam/int
import gleam/list
import gleam/result
import pngleam/parse

pub type Adam7PassInfo {
  Adam7PassInfo(x_start: Int, y_start: Int, x_step: Int, y_step: Int)
}

pub const adam7_passes = [
  Adam7PassInfo(0, 0, 8, 8),
  Adam7PassInfo(4, 0, 8, 8),
  Adam7PassInfo(0, 4, 4, 8),
  Adam7PassInfo(2, 0, 4, 4),
  Adam7PassInfo(0, 2, 2, 4),
  Adam7PassInfo(1, 0, 2, 2),
  Adam7PassInfo(0, 1, 1, 2),
]

pub type Adam7Pixel {
  SubBytePixel(Int)
  BytePixel(BitArray)
}

pub fn extract_pixels_sub_byte(
  row: BitArray,
  bit_depth: Int,
  count: Int,
  acc: List(Int),
) -> List(Int) {
  case count <= 0 {
    True -> list.reverse(acc)
    False ->
      case row {
        <<v:size(bit_depth), rest:bits>> ->
          extract_pixels_sub_byte(rest, bit_depth, count - 1, [v, ..acc])
        _ -> list.reverse(acc)
      }
  }
}

pub fn extract_pixels_bytes(
  row: BitArray,
  pixel_bytes: Int,
  count: Int,
  acc: List(BitArray),
) -> List(BitArray) {
  case count <= 0 {
    True -> list.reverse(acc)
    False ->
      case row {
        <<pixel:bytes-size(pixel_bytes), rest:bits>> ->
          extract_pixels_bytes(rest, pixel_bytes, count - 1, [pixel, ..acc])
        _ -> list.reverse(acc)
      }
  }
}

pub fn populate_pass_pixels(
  pass_rows: List(BitArray),
  pass: Adam7PassInfo,
  pass_w: Int,
  bit_depth: Int,
  bpp_bits: Int,
  pixel_dict: dict.Dict(#(Int, Int), Adam7Pixel),
) -> dict.Dict(#(Int, Int), Adam7Pixel) {
  pass_rows
  |> list.index_fold(pixel_dict, fn(acc_dict, row, py) {
    let y = pass.y_start + py * pass.y_step
    case bpp_bits < 8 {
      True -> {
        let pixels = extract_pixels_sub_byte(row, bit_depth, pass_w, [])
        pixels
        |> list.index_fold(acc_dict, fn(dict_acc, v, px) {
          let x = pass.x_start + px * pass.x_step
          dict.insert(dict_acc, #(x, y), SubBytePixel(v))
        })
      }
      False -> {
        let pixel_bytes = bpp_bits / 8
        let pixels = extract_pixels_bytes(row, pixel_bytes, pass_w, [])
        pixels
        |> list.index_fold(acc_dict, fn(dict_acc, p_bytes, px) {
          let x = pass.x_start + px * pass.x_step
          dict.insert(dict_acc, #(x, y), BytePixel(p_bytes))
        })
      }
    }
  })
}

pub fn do_parse_adam7_passes(
  image_data: BitArray,
  passes: List(Adam7PassInfo),
  width: Int,
  height: Int,
  bit_depth: Int,
  bpp_bits: Int,
  bpp: Int,
  pixel_dict: dict.Dict(#(Int, Int), Adam7Pixel),
) -> Result(dict.Dict(#(Int, Int), Adam7Pixel), parse.Error) {
  case passes {
    [] ->
      case image_data {
        <<>> -> Ok(pixel_dict)
        _ -> Error(parse.InvalidRowData)
      }
    [pass, ..rest_passes] -> {
      let pass_w = case width > pass.x_start {
        True -> { width - pass.x_start + pass.x_step - 1 } / pass.x_step
        False -> 0
      }
      let pass_h = case height > pass.y_start {
        True -> { height - pass.y_start + pass.y_step - 1 } / pass.y_step
        False -> 0
      }
      case pass_w > 0 && pass_h > 0 {
        False ->
          do_parse_adam7_passes(
            image_data,
            rest_passes,
            width,
            height,
            bit_depth,
            bpp_bits,
            bpp,
            pixel_dict,
          )
        True -> {
          let pass_row_size = { pass_w * bpp_bits + 7 } / 8
          let bytes_needed = pass_h * { 1 + pass_row_size }
          case image_data {
            <<pass_bytes:bytes-size(bytes_needed), remaining_data:bits>> -> {
              use pass_rows <- result.try(
                parse.do_image_rows(pass_bytes, pass_row_size, bpp, []),
              )
              let updated_dict =
                populate_pass_pixels(
                  pass_rows,
                  pass,
                  pass_w,
                  bit_depth,
                  bpp_bits,
                  pixel_dict,
                )
              do_parse_adam7_passes(
                remaining_data,
                rest_passes,
                width,
                height,
                bit_depth,
                bpp_bits,
                bpp,
                updated_dict,
              )
            }
            _ -> Error(parse.InvalidRowData)
          }
        }
      }
    }
  }
}

pub fn build_single_row(
  pixel_dict: dict.Dict(#(Int, Int), Adam7Pixel),
  y: Int,
  width: Int,
  bit_depth: Int,
  bpp_bits: Int,
  row_size: Int,
) -> BitArray {
  case bpp_bits < 8 {
    True -> {
      let row_bits =
        int.range(0, width, <<>>, fn(acc, x) {
          case dict.get(pixel_dict, #(x, y)) {
            Ok(SubBytePixel(v)) -> <<acc:bits, v:size(bit_depth)>>
            _ -> <<acc:bits, 0:size(bit_depth)>>
          }
        })

      let padding_bits = { row_size * 8 } - { width * bit_depth }
      case padding_bits > 0 {
        True -> <<row_bits:bits, 0:size(padding_bits)>>
        False -> row_bits
      }
    }
    False -> {
      int.range(0, width, <<>>, fn(acc, x) {
        case dict.get(pixel_dict, #(x, y)) {
          Ok(BytePixel(p_bytes)) -> <<acc:bits, p_bytes:bits>>
          _ -> acc
        }
      })
    }
  }
}

pub fn build_full_image_rows(
  pixel_dict: dict.Dict(#(Int, Int), Adam7Pixel),
  width: Int,
  height: Int,
  bit_depth: Int,
  bpp_bits: Int,
  row_size: Int,
) -> List(BitArray) {
  case height <= 0 || width <= 0 {
    True -> []
    False -> {
      int.range(0, height, [], fn(acc, y) {
        acc
        |> list.append([
          build_single_row(pixel_dict, y, width, bit_depth, bpp_bits, row_size),
        ])
      })
    }
  }
}

pub fn do_parse_image_adam7(
  image_data: BitArray,
  width: Int,
  height: Int,
  bit_depth: Int,
  bpp_bits: Int,
  bpp: Int,
  row_size: Int,
) -> Result(List(BitArray), parse.Error) {
  use pixel_dict <- result.try(do_parse_adam7_passes(
    image_data,
    adam7_passes,
    width,
    height,
    bit_depth,
    bpp_bits,
    bpp,
    dict.new(),
  ))
  Ok(build_full_image_rows(
    pixel_dict,
    width,
    height,
    bit_depth,
    bpp_bits,
    row_size,
  ))
}
