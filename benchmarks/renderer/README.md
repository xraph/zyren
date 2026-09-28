# Renderer benchmarks

Run the native instancing benchmark from `packages/gpu3d_native`:

```sh
dart run benchmark/instancing.dart
```

It checks 1000 and 10000 copies, one opaque draw, zero instance uploads on camera
motion, 112-byte single-copy updates and stable GPU residency. Each case warms
up for 10 frames and reports 20 samples. Timings include Dart capture, native
worker work, GPU completion and explicit 128x128 pixel readback. They do not
measure presentation FPS or GPU timestamps.

Local macOS Metal results on 28 September 2026:

| Copies | Edit | Median readback frame | P95 | Upload per frame |
| --- | --- | --- | --- | --- |
| 1000 | Camera | 1.765 ms | 2.930 ms | 0 B |
| 1000 | One transform | 1.893 ms | 3.206 ms | 112 B |
| 10000 | Camera | 1.191 ms | 2.946 ms | 0 B |
| 10000 | One transform | 2.438 ms | 3.231 ms | 112 B |

These short runs include scheduling and warm-up variation. Use repeated runs on
your target device before making a performance decision. Native Rust tests also
inspect the actual draw loop and pipeline cache, confirming one draw and one
pipeline variant for 10000 opaque copies.
