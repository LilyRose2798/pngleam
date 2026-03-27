# pngleam

[![Package Version](https://img.shields.io/hexpm/v/pngleam)](https://hex.pm/packages/pngleam)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/pngleam/)

```sh
gleam add pngleam@2
```
```gleam
import pngleam
import simplifile

pub fn main() {
  let assert Ok(data) = simplifile.read_bits("example.png")

  // parse a PNG file
  let assert Ok(pngleam.PngImage(metadata:, image_data:, ..)) = pngleam.parse_png(data)

  // get the value of a pixel in the image
  let assert Ok(pixel) = pngleam.read_pixel_at(png, x: 123, y: 456)

  // read an entire row of pixels from the image
  let assert [row, ..] = image_data
  let assert Ok(pixels) = pngleam.read_transparent_colour_pixel_row(row, metadata.bit_depth)

  // fold over all the pixels in an image
  let assert Ok(total_green) = pngleam.fold_transparent_colour_pixels(
    png,
    0,
    fn(total_green, x, y, pixel) {
      total_green + rgb.g
    }
  )

  // create a PNG file pixel by pixel
  let assert Ok(png) = pngleam.simple_render_greyscale_png(
    width: 16,
    height: 16,
    bit_depth: 8,
    pixel: fn(x, y) {
      16 * y + x
    },
    compression_level: Some(9),
  )
  simplifile.write_bits("new.png", png)

  // create a PNG from existing row data
  let assert Ok(png) = pngleam.render_png_rows(
    rows: [
      <<255, 0, 0, 255, 255, 255, 0, 128, 255, 0, 0, 255, 255, 255, 0, 128>>,
      <<255, 128, 0, 255, 0, 255, 0, 255, 255, 128, 0, 255, 0, 255, 0, 255>>,
      <<255, 0, 128, 255, 255, 0, 0, 128, 255, 0, 128, 255, 255, 0, 0, 128>>,
      <<255, 0, 0, 255, 255, 255, 0, 255, 255, 0, 0, 255, 255, 255, 0, 255>>,
    ],
    width: 4,
    height: 4,
    colour_type: Colour(alpha: True),
    bit_depth: 8,
    palette: None,
    compression_level: None,
  )
}
```

Further documentation can be found at <https://hexdocs.pm/pngleam>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
