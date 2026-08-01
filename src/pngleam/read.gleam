import gleam/list

pub fn do_read_values(
  row: BitArray,
  bit_depth: Int,
  acc: List(Int),
) -> List(Int) {
  case row {
    <<v:size(bit_depth), row:bits>> ->
      do_read_values(row, bit_depth, [v, ..acc])
    _ -> list.reverse(acc)
  }
}

pub fn do_read_va(
  row: BitArray,
  bit_depth: Int,
  acc: List(va),
  make_va: fn(Int, Int) -> va,
) -> List(va) {
  case row {
    <<v:size(bit_depth), a:size(bit_depth), row:bits>> ->
      do_read_va(row, bit_depth, [make_va(v, a), ..acc], make_va)
    _ -> list.reverse(acc)
  }
}

pub fn do_read_rgb(
  row: BitArray,
  bit_depth: Int,
  acc: List(rgb),
  make_rgb: fn(Int, Int, Int) -> rgb,
) -> List(rgb) {
  case row {
    <<r:size(bit_depth), g:size(bit_depth), b:size(bit_depth), row:bits>> ->
      do_read_rgb(row, bit_depth, [make_rgb(r, g, b), ..acc], make_rgb)
    _ -> list.reverse(acc)
  }
}

pub fn do_read_rgba(
  row: BitArray,
  bit_depth: Int,
  acc: List(rgba),
  make_rgba: fn(Int, Int, Int, Int) -> rgba,
) -> List(rgba) {
  case row {
    <<
      r:size(bit_depth),
      g:size(bit_depth),
      b:size(bit_depth),
      a:size(bit_depth),
      row:bits,
    >> ->
      do_read_rgba(row, bit_depth, [make_rgba(r, g, b, a), ..acc], make_rgba)
    _ -> list.reverse(acc)
  }
}
