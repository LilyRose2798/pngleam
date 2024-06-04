# pngleam

[![Package Version](https://img.shields.io/hexpm/v/pngleam)](https://hex.pm/packages/pngleam)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/pngleam/)

```sh
gleam add pngleam
```
```gleam
import pngleam

pub fn main() {
  [
    <<0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF>>,
    <<0xFF, 0xFF, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00, 0xFF>>,
    <<0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x80, 0x80, 0x80>>,
  ]
  |> pngleam.from_packed(
    width: 3,
    height: 3,
    color_info: pngleam.rgb_8bit,
    compression_level: pngleam.default_compression,
  )
  |> simplifile.write_bits("img.png", _)
}
```

Further documentation can be found at <https://hexdocs.pm/pngleam>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
