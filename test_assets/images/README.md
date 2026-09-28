# Image fixtures

These images were generated for this repository. They contain no external artwork
and use the repository's MIT license.

- `corners.png`: 2 by 2 RGBA pixels, top-down red (alpha 128), green (255),
  blue (0), white (255). Encoded with image 0.25.10's PNG encoder.
- `gray.jpg`: 8 by 8 RGB pixels, all channels 128. Encoded with image 0.25.10's
  JPEG encoder at quality 100.
- `gray-progressive.jpg`: the same gray field, encoded with Pillow 12.2.0 at
  quality 100 and `progressive=True`.

You can use the corners to check row orientation, channel order and straight
alpha. JPEG checks allow one channel value of rounding error. The Flutter
example bundles identical copies of the first two files under
`examples/multiple_views/assets/images`. Keep those copies in sync when you
change a fixture.
