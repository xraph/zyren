# Core integration and surface picking

You need surface hits before EnvironmentControls and GlobeControls can drag
terrain or maintain height clearance. This slice brings the committed renderer
work into the port and gives ordinary native scenes the same picking API.

Spec: [native API](../design/native-3d-api.md), especially picking and coordinate
contracts. Source scope: [C02 and R2](matrix.md). The existing camera contract
uses world-space position, target and up. Keep the supplied upstream snapshot
unchanged and preserve the separate core checkout.

## Task 1: Integrate the committed core

- [x] Merge core commit `4b619c0` into `geospatial-parity`, preserving the port's
  cameras, controls, input and geodesy. Do not change the core branch.
- [x] Run core and Flutter host suites, analyzer, Rust checks and package guards.
  Expected: the combined APIs and binary submissions preserve existing behavior.
- [x] Select the public native Android runtime in the orbit lab and verify both
  camera modes through Metal and Vulkan with no ordinary readback.
- [x] Record the combined checkpoint and make a focused local merge commit.

## Task 2: Add generic CPU mesh picking

- [x] Add failing tests for nearest triangle hits, misses, edges, nonuniform and
  mirrored transforms, hidden ancestors, finite range, normals, UVs and scene
  revisions. Expected: missing public picking behavior fails first.
- [x] Implement immutable bounds, per-geometry triangle acceleration and a
  public Raycaster over visible static meshes. Reuse camera rays and preserve
  world-space distances. Match the renderer's current double-sided triangles.
- [x] Validate invalid rays/ranges and numerically singular transforms. Return
  typed invalid-request errors rather than nonfinite intersections.
- [x] Check independent upstream fixtures, run the core suite, analyzer and
  formatting, then commit the tested picking API.

## Task 3: Connect viewport picking and native selection

- [x] Add failing host tests for logical viewport coordinates across DPR and
  render scales, camera/scene changes after the request, disposal and detachment.
- [x] Expose SceneController.pick with a result captured at call time. Return
  object, world point, world distance, triangle index, optional UV and revision.
- [x] Add a compact picking lab that highlights the selected mesh and displays
  its hit position. Exercise perspective and orthographic projection through the
  public controller API on native Metal and Vulkan.
- [ ] Run affected suites, native integration and package guards. Record actual
  evidence and remaining gaps, then commit and obtain one fresh final review.

## Limits

This slice supports the core's current immutable indexed meshes. Instancing,
deformed geometry, layer masks and render culling need their corresponding
renderer contracts. They remain in the program plan. EnvironmentControls and
GlobeControls follow this picking prerequisite and are not claimed by this slice.
