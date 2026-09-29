# Core implementation and validation

The five families in the [core plan](superpowers/plans/2026-09-28-core-completion.md)
are implemented in the `dart-core-api` checkout. You can exercise the native
material and effect pipeline with `examples/shader_lab/lib/physical.dart`.
Geospatial remains an optional plugin. No browser rendering path was added.

## Delivered

| Family | Implementation | Local commits |
| --- | --- | --- |
| Physical materials | IOR/specular, clearcoat, sheen, anisotropy, ten layer maps, glTF extensions, transmission and volume absorption | `9ab45b9`, `bdf80dc`, `12457e9` |
| Area lighting | Oriented rectangular emitters, diffuse and glossy integration, physical layers and bounded light count | `56955aa` |
| Compressed assets | Optional native CPU services for Draco, meshopt and Basis/KTX2, bounded decoding and glTF integration | `b65c94f` |
| Geometry and controls | Polygon holes, beveled extrusion, geometry utilities, trackball and fly controls | `11fc927` |
| Temporal AA | Jitter, motion/depth reprojection, neighborhood clipping, per-view history, reset and allocation limits | `9e5a9ec` |
| Performance and final fixes | Transmission residency audit, AOT profiles, material coverage and independent coat UV frames | `a491e58`, `2bf5962` |

## Final checks

The 29 September 2026 validation used the implementation at `2bf5962` on an
Apple M3 Max. All tests listed below passed.

| Suite | Result |
| --- | --- |
| Dart core | 399 tests |
| glTF loader | 122 tests |
| Native Dart tests, including Metal pixels | 133 tests |
| Flutter package | 84 tests |
| Rust ordinary tests | 109 tests |
| Rust hardware-gated tests, explicitly enabled | 37 tests |
| Physical gallery on macOS Metal | Surface, controls and resize passed |
| Physical gallery on iPhone 17 Pro, iOS 26 simulator | Surface, controls and resize passed |

The gallery checks switch area lighting, MSAA, temporal AA and bloom, resize to
320x640 and 960x720, and require zero presentation readback. Simulator execution
uses the host GPU. It does not qualify a physical iPhone.

Analysis of `packages`, `examples` and `tool` reports no issues. Rust formatting,
strict all-target Clippy, package boundaries and Apple ABI header checks pass.
The workspace-root analyzer also sees nine informational lints in two ignored
local scripts under `artifacts`; those scripts are outside the shipped packages.

One final review found three material defects. Each received a failing regression
before its fix, then passed the focused and full suites:

- A metallic map can reduce a metallic factor of one. Such a material now gets
  the transmission capture and reactive temporal treatment that its pixels need.
- Retained thickness no longer removes opaque backfaces when transmission is
  disabled, masked to zero or suppressed by metallic shading.
- A coat normal map on a different UV set now derives its own frame instead of
  reusing tangents for the base normal map. The rotated-UV pixel fixture matches
  an explicit geometric-normal reference.

All review findings were fixed. None were deferred.

## Resource and timing evidence

The [physical-material AOT run](../benchmarks/renderer/2026-09-29-physical-metal-300.json)
records 18 profile/size combinations with 30 warmup and 300 measured frames each.
It preserves its source identity, `12457e9`, before the final edge-case fixes.
Scoped, temporal and transmission allocations stayed constant during measurement
and returned to zero after view disposal. Every steady frame uploaded zero
geometry, instance and texture bytes.

At 1280x720, the glass profile measured 1.162 ms median and 1.320 ms P95. Glass
with temporal AA measured 1.405 ms median and 1.474 ms P95. These timings include
readback. GPU timestamps, display pacing, power and thermal state were not measured.
The [benchmark notes](../benchmarks/renderer/README.md) describe the fixture and
separate capture, temporal and scoped resource accounting.

## Qualification limits

You still need physical iOS, Android Vulkan and Windows DX12 qualification for
these additions. The macOS app ran, but an asleep display prevented foregrounding;
manual visual inspection remains open.

This completes the planned feature families, not every Three.js API. The
[capability matrix](renderer-capabilities.md) records remaining breadth:
iridescence and dispersion, nested refractive volumes, area-light shadows,
compressed GPU texture residency, text/subdivision/CSG, additional asset formats,
and temporal motion for custom shaders and line/point primitives. Basis currently
transcodes to RGBA8. Transmission uses an opaque scene capture. Temporal AA requires
single-sample HDR and cannot run simultaneously with MSAA.

Takram geospatial parity is separate plugin work. This checkout has not merged
the concurrent Zyren changes from the primary checkout.

## Reproduce

Run Dart and Flutter suites from their package directories. Native build hooks
need the consuming package as the working directory:

```sh
# packages/gpu3d and packages/gpu3d_gltf
dart test

# packages/gpu3d_native
RUN_NATIVE_GPU=1 dart test --concurrency=1

# packages/flutter_gpu3d
flutter test
```

From the repository root:

```sh
cargo +1.97.1 test --manifest-path packages/gpu3d_native/native/Cargo.toml -- --test-threads=1
cargo +1.97.1 test --manifest-path packages/gpu3d_native/native/Cargo.toml -- --ignored --test-threads=1
cargo +1.97.1 clippy --manifest-path packages/gpu3d_native/native/Cargo.toml --all-targets -- -D warnings
dart run tool/check_package_boundaries.dart
dart run tool/sync_apple_header.dart --check
```

From `examples/shader_lab`:

```sh
flutter test integration_test/physical_test.dart -d macos
flutter run -d macos -t lib/physical.dart
```

Run GPU workloads serially. Use an available iOS simulator identifier in place
of `macos` for the simulator fixture.
