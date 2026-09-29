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
nested refractive volumes, continuous emitter visibility, text/subdivision/CSG,
additional asset formats, and temporal motion for custom shaders and line/point
primitives. Iridescence, dispersion, area shadows and compressed GPU residency
are implemented in the follow-up below. Transmission uses an opaque scene capture. Temporal AA requires
single-sample HDR and cannot run simultaneously with MSAA.

Takram geospatial parity is separate plugin work. This checkout has not merged
the concurrent Zyren changes from the primary checkout.

## Reproduce

Run Dart and Flutter suites from their package directories. Native build hooks
need the consuming package as the working directory:

```sh
# packages/zyren and packages/zyren_gltf
dart test

# packages/zyren_native
RUN_NATIVE_GPU=1 dart test --concurrency=1

# packages/flutter_zyren
flutter test
```

From the repository root:

```sh
cargo +1.97.1 test --manifest-path packages/zyren_native/native/Cargo.toml -- --test-threads=1
cargo +1.97.1 test --manifest-path packages/zyren_native/native/Cargo.toml -- --ignored --test-threads=1
cargo +1.97.1 clippy --manifest-path packages/zyren_native/native/Cargo.toml --all-targets -- -D warnings
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

## Optics, area shadows and GPU compression

The [follow-up plan](superpowers/plans/2026-09-29-core-optics-shadows-compression.md)
adds the three requested core capabilities:

| Change | Local commit | Evidence |
| --- | --- | --- |
| Iridescence and dispersion | `e3076f1` | Thin-film reference colors, independent RGB refraction paths, two linear maps, glTF extensions and native material variants |
| Rectangular area shadows | `73e3339` | Full/partial occlusion, motion, receiver/caster flags, 97 simultaneous projections, cache reuse and atlas retirement |
| Compressed GPU residency | `1c117a0` | BC7, ETC2 RGBA8 and ASTC 4x4 sampling, exact raw block readback, authored mip tails, capability admission and zero final residency |
| Gallery and device admission | `d9749da` | Native optical controls, compressed asset loading, narrow layout and rejection before unsupported GPU allocation |
| Final edge cases | `46f3bf4` | Geometric shadow bias, exact zero-film lighting and camera-rotation shadow cache reuse |

The implementation at `46f3bf4` passes 405 core, 124 loader, 141 native Dart and
84 Flutter package tests. All 151 Rust tests pass with hardware-gated cases
enabled. Analysis of `packages`, `examples` and `tool`, strict Clippy, formatting,
package boundaries and Apple ABI checks pass. The default CPU decoder stays RGBA8 for loading before a renderer
exists. Use `NativeTextureDecoder.forDevice` when you want compressed residency.

Area shadows sample four regions of an emitter. This gives partial visibility
with a fixed budget, but can show bands and does not integrate visibility
continuously over the rectangle. Dispersion uses three paths through the opaque
scene capture; nested refraction and caustics remain outside this profile.

The updated physical gallery passes macOS Metal and the iPhone 17 Pro iOS 26
simulator checks, both repeated after the final shader fixes. It exercises
film/dispersion/shadow controls, compressed texture
loading, MSAA/TAA/bloom, and desktop/narrow resizing with zero presentation
readback. Narrow slider layout uses the panel width, so a smaller embedded view
keeps useful canvas space even when the device screen is wider.

The follow-up review found two issues, both fixed with regressions that failed
before the shader changes: area-shadow bias now uses the geometric normal, and
zero-thickness iridescence keeps the baseline area-light path. A benchmark-triggered
regression also fixes unnecessary atlas rebuilds when the camera rotates.
Translation still changes relative-coordinate depth inputs, so the benchmark
records redraws rather than treating them as leaks. No review minors were deferred.

The retained API decisions are explicit: thickness endpoints may be reversed;
compressed base dimensions must align to four pixels and mips must be authored;
materials exceeding device binding limits fail admission. These choices can
require asset preprocessing or simpler materials on limited devices. Physical
iOS, Android and Windows remain qualification gates, with target-specific driver
behavior still unverified.

The [final optics benchmark](../benchmarks/renderer/2026-09-29-optics-metal-300.json)
records 14 profile/size combinations at `46f3bf4`, each with 30 warmup and 300
measured frames. At 1280x720, area shadows measure 2.388 ms median and 2.586 ms
P95. The combined iridescence, dispersion, area-shadow and TAA fixture measures
15.192 ms median and 16.844 ms P95. These are end-to-end readback timings on an
M3 Max; GPU timestamps, display pacing, power and thermal state remain unknown.

The compressed fixture holds 112 bytes of ASTC mip payload, versus 340 bytes as
RGBA. Each shadowed view holds a 16 MiB atlas. Camera translation redraws 24
projections per shadowed area light per frame; camera rotation reuses depth.
All steady frames upload zero scene-resource bytes. Scoped, shadow, temporal
and transmission residency stays stable during the run and reaches zero after
each view closes. These counters exclude normal frame targets, driver padding
and staging. The [benchmark notes](../benchmarks/renderer/README.md) record the
fixture and its costs.
