# W5 opaque scene inputs

The generic native mesh API now exposes current-frame opaque HDR color and depth.
This is the input transport for W6 optics and W7 underwater effects. Neither water
stage is qualified by this fixture.

## Checks

- Twelve native tests passed across `mesh_scene_inputs_test.dart`,
  `mesh_shader_test.dart`, `shader_material_test.dart` and `transmission_test.dart`
  with `RUN_NATIVE_GPU=1`, using the FVM Flutter 3.47.5 SDK on macOS Metal.
- The new fixture covers both custom mesh compiler APIs; standard and reversed
  depth; one and four samples; perspective and orthographic reconstruction;
  current-frame opaque color changes; HDR values above one; SDR final output;
  preserved foreground geometry; alpha exclusion and final alpha composition;
  two views; resize; failed target admission; and release after consumers hide.
- Twelve core tests passed across scene-input, mesh-shader and material-compiler
  tests. They cover reserved-group rejection and capability failure before backend
  submission as well as existing compiler ownership behavior.
- Rust capture-admission tests cover four-sample byte accounting and unsupported
  sample counts. The native ignored retirement test
  `retired_transmission_textures_are_not_retained_by_any_cached_view` passed.

The rough-glass alpha regression used an old normal-incidence expectation after
the renderer adopted integrated GGX reflected energy. Its assertion now uses the
existing independent numerical BRDF reference. The corrected native test passes;
no production PBR behavior was changed for this assertion.

Owned-file analysis and package boundary checks passed.

## Contract and limits

Group three is reserved only for opted-in programs. Compiled program metadata
drives capture admission; scene packets cannot claim the capability independently.
The capture excludes consumers, physical transmission surfaces and alpha blends.
Depth reconstruction is camera-relative and uses the current projection.
RGBA16F capture stays linear until final display processing. MSAA depth selects
the nearest covered sample; color averages samples.

The 128 MiB capture allowance includes old and candidate color/depth resources
and multisample attachments. Counters report logical payload bytes. Physical GPU
residency is unknown. Mobile and Windows devices remain unqualified. No manual
water review, frame-rate target or professional visual acceptance is claimed.

API details: [mesh scene inputs](../../packages/zyren_native/doc/mesh-scene-inputs.md).
