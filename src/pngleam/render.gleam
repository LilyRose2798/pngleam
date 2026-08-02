import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gzlib

pub type Error {
  UnalignedData
  InvalidBitDepth
  InvalidCompressionLevel
}

pub const signature = <<137, 80, 78, 71, 13, 10, 26, 10>>

pub fn do_chunk_bits(data: BitArray, chunks: List(BitArray)) -> List(BitArray) {
  case data {
    <<chunk:bytes-8192, rest:bits>> -> do_chunk_bits(rest, [chunk, ..chunks])
    _ -> list.reverse([data, ..chunks])
  }
}

pub fn chunk(tag: BitArray, data: BitArray) -> Result(BitArray, Error) {
  case gzlib.crc32(tag) |> result.try(gzlib.crc32_continue(_, data)) {
    Ok(checksum) ->
      Ok(<<bit_array.byte_size(data):32, tag:bits, data:bits, checksum:32>>)
    Error(Nil) -> Error(UnalignedData)
  }
}

pub fn do_flatten_rows(rows: List(BitArray), acc: BitArray) -> BitArray {
  case rows {
    [] -> acc
    [row, ..rows] -> do_flatten_rows(rows, <<acc:bits, 0, row:bits>>)
  }
}

pub fn rows(
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

pub fn simple_render_rows(
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

pub fn max_value(bit_depth: Int) -> Int {
  int.bitwise_shift_left(1, bit_depth) - 1
}

pub fn value(bit_depth: Int) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row, value) { <<row:bits, int.clamp(value, min:, max:):size(bit_depth)>> }
}

pub fn va(bit_depth: Int, get_v_a: fn(va) -> #(Int, Int)) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row: BitArray, va: va) {
    let #(v, a) = get_v_a(va)
    <<
      row:bits,
      int.clamp(v, min:, max:):size(bit_depth),
      int.clamp(a, min:, max:):size(bit_depth),
    >>
  }
}

pub fn rgb(bit_depth: Int, get_r_g_b: fn(rgb) -> #(Int, Int, Int)) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row: BitArray, rgb: rgb) {
    let #(r, g, b) = get_r_g_b(rgb)
    <<
      row:bits,
      int.clamp(r, min:, max:):size(bit_depth),
      int.clamp(g, min:, max:):size(bit_depth),
      int.clamp(b, min:, max:):size(bit_depth),
    >>
  }
}

pub fn rgba(bit_depth: Int, get_r_g_b_a: fn(rgba) -> #(Int, Int, Int, Int)) {
  let min = 0
  let max = max_value(bit_depth)
  fn(row: BitArray, rgba: rgba) {
    let #(r, g, b, a) = get_r_g_b_a(rgba)
    <<
      row:bits,
      int.clamp(r, min:, max:):size(bit_depth),
      int.clamp(g, min:, max:):size(bit_depth),
      int.clamp(b, min:, max:):size(bit_depth),
      int.clamp(a, min:, max:):size(bit_depth),
    >>
  }
}
