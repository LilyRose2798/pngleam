import gleam/int
import gleam/list
import gleam/string
import gleeunit
import pngleam
import simplifile

fn do_rgba_string(data: BitArray, acc: String) -> String {
  case data {
    <<>> -> acc
    <<r, g, b, a, rest:bytes>> ->
      do_rgba_string(
        rest,
        acc
          <> "#"
          <> [r, g, b, a]
        |> list.map(int.to_base16)
        |> list.map(string.pad_start(_, 2, "0"))
        |> string.join("")
          <> " ",
      )
    _ -> panic
  }
}

pub fn main() {
  let assert Ok(data) = simplifile.read_bits("test.png")
  let assert Ok(pngleam.PngImage(metadata:, palette:, image_data:, other_data:)) =
    pngleam.parse_png(data)
  echo metadata
  echo palette
  echo image_data
  echo other_data
  let assert Ok(Nil) =
    simplifile.write(
      to: "test.txt",
      contents: string.join(list.map(image_data, do_rgba_string(_, "")), "\n"),
    )
  gleeunit.main()
}
