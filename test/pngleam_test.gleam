import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleeunit
import pngleam
import simplifile

fn do_bit_array_to_string(data: BitArray, acc: List(String)) -> List(String) {
  case data {
    <<>> -> acc
    <<a, b, c, d, rest:bytes>> ->
      do_bit_array_to_string(rest, [
        "("
          <> [a, b, c, d]
        |> list.map(int.to_string)
        |> list.map(string.pad_left(_, 3, " "))
        |> string.join(", ")
          <> ")",
        ..acc
      ])
    _ -> panic
  }
}

fn bit_array_to_string(data: BitArray) -> String {
  do_bit_array_to_string(data, []) |> list.reverse |> string.join("    ")
}

pub fn main() {
  let assert Ok(data) = simplifile.read_bits("shinobu.png")
  // let assert Ok(metadata) = pngleam.parse_metadata(data)
  let assert Ok(pngleam.PngData(metadata, _palette, img_data)) =
    pngleam.parse_to_bit_arrays(data)
  io.debug(metadata)
  // io.debug(palette)
  let assert Ok(Nil) =
    simplifile.write(
      to: "shinobu-erl.txt",
      contents: string.join(list.map(img_data, bit_array_to_string), "\n"),
    )
  // io.debug(img_data)
  // io.debug(list.length(img_data))
  // let assert pngleam.ColorWithAlphaData([first_row, ..]) = img_data
  // io.debug(first_row |> list.map(fn(t) { [t.0, t.1, t.2, t.3] }))
  // let assert pngleam.IndexedData([first_row, ..]) = img_data
  // io.debug(first_row)
  gleeunit.main()
}
