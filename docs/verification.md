# Verification

Checked locally on 26 September 2026 with Flutter 3.47.5, Dart 3.13.4,
Rust 1.97.1 and Xcode 27.0.

| Target | Build | Runtime evidence |
| --- | --- | --- |
| macOS ARM64 | Debug app passed | Apple M3 Max / Metal pixel tests, Dart FFI tests and Flutter integration test passed; globe and wrapping controls inspected in desktop and narrow native windows |
| iOS ARM64 simulator | Debug app passed | iPhone 17 Pro simulator on iOS 26.0 passed the Flutter integration test with a rendered native image |
| Android ARM64 | Debug APK passed | No device run yet |
| iOS physical device | Build target configured | Signing, device deployment and GPU behaviour not verified |
| Windows | Build hook and CI job configured | No Windows host build or runtime verification yet |
| Linux | Build hook and CI job configured | No Linux host build or runtime verification yet |
| Other CPU architectures | Rust target declarations configured | Not built or tested locally |

The CI workflow has been written but has not run remotely. Nothing has been
pushed. A simulator pass does not establish physical mobile GPU performance.

## Checks passed

- Rust: three tests, including the explicitly enabled native GPU test. Assertions
  cover actual pixels, front/back depth ordering, row padding, target resizing up
  to 4096 pixels, geometry release, malformed scenes and handle/finalizer cleanup.
- Dart: four scene/geometry tests and five geodesy tests. The geodetic round-trip
  test covers 200 combinations across WGS84 and a triaxial ellipsoid, including
  poles, the date line, negative heights and orbital altitudes.
- Plugins and viewports: 21 tests cover dependency ordering, typed services,
  unsupported capabilities, partial attach rollback, exclusive ownership, frame
  timing, injected renderer/presenter implementations, pending-frame replacement,
  initialization cancellation, retries, error-observer and frame-cleanup failures,
  background/resume and separate world models. The core imports no geospatial package.
- Dart/native: one FFI test covers actual pixels from a worker isolate, geometry
  eviction/re-upload, resizing, concurrent-frame rejection and disposal while a
  frame is in flight.
- Flutter integration: desktop and 390-pixel layouts, city selection, a non-null
  rendered GPU image and viewport removal. The plugin test also checks that city
  selection changes the camera through the orbit plugin and produces a new image.
- Flutter analysis, Dart formatting, Rust formatting and Clippy passed.

## Known limits

Presentation copies RGBA data from the GPU to Dart and back into Flutter. No
frame-rate target or zero-copy claim has been verified. The renderer supports
opaque indexed meshes, diffuse directional lighting and an unlit material.
Custom native shader/pass registration, texture loading, glTF, PBR, shadows,
animation clips, picking, terrain streaming, atmosphere and clouds are not
implemented.

Geometry uploads are limited to one million vertices and three million indices
per frame. Resident geometry has a 64 MiB budget; frames support 1 to 4096 pixels
per axis and up to 4096 mesh instances. The protocol rejects unsupported sizes
and invalid data before rendering.

The build disables Rust's release debuginfo stripping because it produced a
misaligned Mach-O string table rejected by this macOS 27 host. The issue and
workaround are recorded in [rust-lang/rust#157750](https://github.com/rust-lang/rust/issues/157750).
The FFI test verifies that the resulting library actually loads.
