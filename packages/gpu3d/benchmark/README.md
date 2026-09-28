# Picking benchmark

Run this from the repository root with the development Dart SDK:

```sh
dart compile exe packages/gpu3d/benchmark/picking.dart -o artifacts/picking-benchmark
artifacts/picking-benchmark > artifacts/picking-benchmark.json
```

You get JSON timings for cold capture, repeated queries and one edit before each
query. Both the BVH and linear paths retain their raycaster between samples.
The fixtures contain a 32,768-triangle grid and 10,000 box instances. Each query
returns the nearest hit. The edit moves one grid vertex or one instance.

The clock includes capture and traversal, but excludes applying the edit before
capture. It does not include a renderer, GPU work or Flutter presentation.
Ten warmups precede 40 steady samples and 20 edit samples. `sampleCounters`
reports the last sample in each group, not an average. Timings use microsecond
clock resolution, so treat the smallest values as approximate.

## Local release baseline

Measured on 28 September 2026, Apple M3 Max, macOS arm64, Dart 3.13.4 AOT.
Times below include capture and traversal, in milliseconds.

| Fixture | Method | Cold | Steady p50 / p95 | One edit p50 / p95 |
| --- | --- | ---: | ---: | ---: |
| 32,768 triangles | BVH | 28.219 | 0.002 / 0.003 | 4.266 / 10.836 |
| 32,768 triangles | Linear | 2.965 | 2.034 / 2.170 | 2.327 / 2.455 |
| 10,000 instances | BVH | 24.325 | 0.003 / 0.004 | 2.013 / 4.317 |
| 10,000 instances | Linear | 16.074 | 0.868 / 1.214 | 3.181 / 3.574 |

The grid query tests eight triangles with BVH and 32,768 without it. The instance
query visits four mesh records with BVH and 10,000 without it; both paths then
test twelve triangles. After an instance edit, only that instance's model inverse
is recomputed. The grid edit refits all triangle bounds, which is more expensive
here than a single linear query.

Run it on your target hardware. These results describe CPU picking on this Mac,
not mobile performance or a frame-rate guarantee. Frozen requests intentionally
retain their captured data, so release old requests when your tool no longer
needs them.
