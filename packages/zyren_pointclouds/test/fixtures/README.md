# Native format fixtures

These are synthetic encoded files created for this repository, under its MIT
licence. They contain no survey or customer data. `native/examples/fixtures.rs`
regenerates them with the pinned LAS/LAZ and E57 writers.

- `survey.las` and `survey.laz` carry the same three samples, LAS 1.4 format 3,
  millimetre scale, large offsets, RGB, intensity, returns, classification,
  withheld state, GPS time and a local CRS WKT record.
- `survey14.laz` carries the same samples in LAS 1.4 format 7 with layered
  compression.
- `scans.e57` contains two scans with separate GUIDs and poses, scaled integer
  coordinates, double intensity and one invalid positional record in each scan.
  The valid flattened source ordinals are 0, 2, 3 and 5.

The tests also derive truncated and excessive-allocation inputs from these files.
They verify encoded format handling, not accuracy of a physical instrument.

From the repository root, regenerate with:

```sh
cargo run --manifest-path packages/zyren_pointclouds/native/Cargo.toml \
  --example fixtures -- packages/zyren_pointclouds/test/fixtures
```
