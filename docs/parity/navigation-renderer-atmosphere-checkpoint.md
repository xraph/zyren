# Navigation, renderer and atmosphere qualification

The requested three feature groups are implemented in the primary checkout on
`main`. This report records the 28 September 2026 qualification. The production
checkpoint is `94daacd`; device limits below still apply. Nothing was pushed.

You can run the public Planet targets `lib/navigation_lab.dart`,
`lib/renderer_lab.dart` and `lib/atmosphere_lab.dart`. They use native presentation
and public package APIs. The geospatial package stays optional; the general Dart
core owns cameras, materials, GPU resources and rendering.

## Delivered scope

- Navigation: perspective/orthographic transitions, environment and globe
  surface controls, wheel/pinch zoom, pivot rotation, inertia, clipping, height
  clearance, native input and picking. See [the replay evidence](native-navigation.md).
- Renderer: scoped buffers and float/volume textures, WGSL mesh/effect pipelines,
  render graphs and compute, linear HDR, metal/rough PBR with maps and tangents,
  lights, environment convolution, directional/spot shadows, stable instances,
  standard glTF loading, MSAA, FXAA and bloom. The [renderer profiles](../renderer-capabilities.md)
  state resource budgets and supported material behavior.
- Atmosphere: UTC celestial frames, four-order RGB scattering tables, bounded
  transactional caching, sky, sun, oriented moon albedo, 9,096 stars and depth
  haze. The [atmosphere evidence](atmosphere.md) records numerical tolerances,
  device results and differences from the supplied source.

## Automated checks

All affected package suites passed. Native tests ran with real Metal execution;
Dart native lifetime tests used one test at a time because their counters are
process-wide.

| Suite | Passed |
| --- | ---: |
| Dart core | 409 |
| Geospatial, including native atmosphere fixtures | 83 |
| Native Dart/FFI with GPU execution | 64 |
| Tools | 53 |
| glTF | 57 |
| Devtools / timeline / engineering | 3 / 7 / 11 |
| Flutter host | 76 |
| Multiple views / model viewer | 13 / 2 |
| Independent shader lab with GPU execution | 3 |
| Rust, including normally ignored GPU tests | 81 |

Workspace analysis, strict Rust Clippy and the package-boundary/Apple-header guard
passed. The final control change has 36 wheel/pinch regressions at speeds 0.5,
1 and 2. Twenty-four failed before the fix; all pass after it, along with the
original default-speed reference traces. Formatting and the staged whitespace
check pass for the final changed code.

The Rust command was `cargo +1.97.1 test -- --include-ignored --test-threads=1`.
Use `RUN_NATIVE_GPU=1 dart test --concurrency=1` in `packages/zyren_native` and
`examples/shader_lab`. Run `dart test --concurrency=1` in the geospatial package;
its atmosphere fixtures execute natively. Other Dart packages use `dart test`,
and the Flutter host and examples use `flutter test`.

## Device results

| Device | Navigation | Renderer | Atmosphere |
| --- | --- | --- | --- |
| macOS, Apple M3 Max, Metal | Pass after the final control fix: 73 native presentations, 17 samples | Both combined renderer tests pass | Pass: 31 native presentations, 11 samples |
| Pixel 9 Pro, Android 17, Vulkan | Final run stopped while keyguard was locked; no completed result | Both combined renderer tests pass | Pass: 18 native presentations, 11 samples |
| iPhone 16 Pro, iOS 27, Metal | No completed result | No completed result | Scene rendered and controls ran, but no complete corrected test result |
| Windows DX12 / Linux Vulkan | Unrun | Unrun | Unrun |

Every passing native run reported zero ordinary presentation readbacks and zero
sessions, renderers, retiring resources and held drawables or surfaces after
disposal. Counts are not frame-rate measurements. The locked Mac prevented
foreground activation, so native counters and separately inspected render images
support these results; they do not establish a manual foreground-window review.

The iPhone profile test rendered day/dusk/night, horizon/orbit and haze, then
failed a fixed 480-pixel canvas assertion at 453 pixels. The corrected test uses
70% of usable height after system safe areas. It passes on Mac. Its iPhone retry
built but Xcode failed to find Runner during launch; a later device check reported
that a passcode was required. Planet remains installed. Both phones need to stay
unlocked to finish the missing checks.

The Pixel atmosphere initially exposed a Mali Vulkan compiler crash when texture
objects passed through shader helpers. Specializing those helpers by global
texture binding retains the numerical bodies and passes Metal reference checks
and Pixel presentation. No OpenGL or browser fallback is involved.

## Review and decisions

One fresh review covered `2116bfa..6315fa0`. It found no critical defect and one
important defect: custom orthographic zoom sensitivity could reverse direction.
Commit `94daacd` fixes it with the red-to-green regressions described above.
The following decisions preserve the execution ledger's order.

1. Work on `main` in the primary checkout, as requested, preserving sibling and
   concurrent work. Cost if wrong: isolation would require a later checkout move.
2. Start navigation while the renderer checkout is active, integrating only its
   committed checkpoints. Cost if wrong: integration may wait for another checkpoint.
3. Cancellation clears pending motion; reset keeps release inertia. Wheel input
   refreshes changed pointer locations. Cost if wrong: synthetic wheel events differ
   from upstream's stale-pointer behavior.
4. Rotation preserves aiming distance for Earth-scale precision, uses the pinned
   slerp threshold and snapshots the action before horizon misses. Cost if wrong:
   a future upstream change needs new trajectory fixtures.
5. Keep orthonormal axes at the faulty upstream tilt boundary; scale horizon
   distances with uniform frames and reject shear/nonuniform scale. Cost if wrong:
   that boundary intentionally differs and unsupported transforms need conversion.
6. Accept the navigation library on verified Mac execution while carrying mobile
   checks into final qualification. Cost if wrong: mobile defects can remain hidden.
7. Clouds and automatic terrain streaming stay outside this slice. Cost if wrong:
   those stories require a separate implementation.
8. Skinning, morphs and animation stay outside the selected instancing milestone.
   Cost if wrong: animated assets require another implementation stage.
9. Qualify bounded directional/spot shadows, spatial AA and single-scattering PBR.
   Cost if wrong: point shadows, temporal AA and broader physical materials need
   dedicated profiles and tests.
10. Expose atmosphere lighting leases without automatically replacing PBR lights
    or environment maps. Cost if wrong: applications must wire lighting explicitly.
11. Platform claims require completed device checks. Cost if wrong: defects on
    iPhone, Windows or other unqualified hosts can remain undiscovered.
12. Haze uses shared scene depth and premultiplied coverage. Cost if wrong:
    overlapping transparent layers need a later layered-depth design.
13. Scale orthographic sensitivity inside the exponent to preserve input direction
    and the neutral factor. Cost if wrong: custom speeds differ from upstream.
14. Measure compact layout against usable height after safe areas. Cost if wrong:
    the permitted absolute canvas height varies with system insets.

## Review follow-up

`AtmosphereLuts.shader(firstBinding: ...)` now rejects offsets above 11 before
constructing a shader library. Five consecutive bindings must fit the core range
0 through 15. The regression first reproduced the missing rejection at 12, then
passed with the fix; it also compiles and executes a real Metal graph at offset
11 and checks that teardown releases every resource. All 83 geospatial tests and
workspace analysis pass. The review's only deferred minor is resolved.

## Remaining scope

The supplied repository's full story matrix is still larger than this slice.
Clouds, terrain/tiles streaming, automatic atmospheric PBR adapters, spectral
integration, per-layer transparent haze, further physical material extensions
and animated glTF are follow-on work. Complete upstream story screenshot parity
has not been established. Track those requirements in the [parity matrix](matrix.md).
