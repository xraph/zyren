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

## HDR effects

Build and run the AOT bundle from `packages/gpu3d_native`:

```sh
dart build cli -t benchmark/post_processing.dart -o build/renderer-profile
build/renderer-profile/bundle/bin/post_processing
```

The bundle includes its native library. `dart compile exe` alone does not.
The 28 September run used an Apple M3 Max with 40 GPU cores and Metal. Each
case renders 400 instanced spheres, warms five frames, then measures 20 frames.
Times include scene capture, worker submission, GPU completion and RGBA readback.
They are not presentation FPS or GPU timestamps.

| Pixels | Profile | Median | P95 | Resident resource payload |
| --- | --- | --- | --- | --- |
| 640×360 | ldr | 1.311 ms | 1.724 ms | 0.06 MiB |
| 640×360 | hdr | 1.304 ms | 1.810 ms | 0.06 MiB |
| 640×360 | msaa4 | 1.273 ms | 1.996 ms | 0.06 MiB |
| 640×360 | bloom | 1.191 ms | 1.604 ms | 4.89 MiB |
| 640×360 | bloom+spatial | 1.285 ms | 1.618 ms | 6.65 MiB |
| 1280×720 | ldr | 1.133 ms | 1.577 ms | 0.06 MiB |
| 1280×720 | hdr | 1.232 ms | 1.688 ms | 0.06 MiB |
| 1280×720 | msaa4 | 1.283 ms | 1.593 ms | 0.06 MiB |
| 1280×720 | bloom | 1.705 ms | 2.199 ms | 19.39 MiB |
| 1280×720 | bloom+spatial | 1.816 ms | 2.112 ms | 26.42 MiB |

Every measured frame uploaded zero geometry/instance/texture bytes. Resource
counts and payload residency remained stable within each profile and returned
to zero after its view was disposed. The counters include scene and graph
resources, but exclude internal frame targets, driver padding and staging.
The GPU time field remains null.

The short samples have scheduling variation, including cases where four samples
measure faster than one. This does not imply that MSAA is free. Repeat the run
on your target device and use a presentation benchmark for frame pacing.
Raw results are in [the Metal sample](2026-09-28-post-processing-metal.json).
