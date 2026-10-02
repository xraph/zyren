# Physics implementation checks

These results were measured on 2026-10-02 with Flutter 3.47.5, its bundled Dart
3.13.4, Rust 1.97.1 and Rapier 0.36.0. You can reproduce the package checks from
`packages/zyren_physics` and the app checks from `examples/physics_lab`.

| Requirement | Implementation and evidence |
| --- | --- |
| Optional native asset, isolated worlds and disposal | Implemented; native isolation, stale handles and cleanup tests |
| Fixed, dynamic and both kinematic modes | Implemented; native pose, force, torque, mass, sleep and reset tests |
| Box, sphere, capsule, convex, mesh and compound | Implemented; native shape validation and query tests |
| Offsets, masks, materials, sensors and CCD | Implemented; offset queries, mask changes, sensor transitions and fast-body CCD regressions |
| Fixed stepping, catch-up, interpolation and ownership | Implemented; bounded stepping, pause, parent transforms, competing writers and single-driver tests |
| Hinge, slider, fixed, spherical, spring and distance | Implemented; native anchor, motor reversal and limit behavior tests. Distance is a maximum-length rope and permits slack |
| Ray, shape and overlap queries | Implemented; native hit, filter and overlap tests |
| Collision, sensor and contact events | Implemented; query transitions survive stepping, removal and snapshot restore; callbacks can remove bound bodies |
| Snapshots and renderer recovery | Implemented; deterministic replay, stale-handle rejection, failed attachment recovery and native Metal renderer recreation |
| Debug geometry | Implemented; collider, joint and contact geometry appears in the saved Metal render |
| Physics Lab | Implemented; controls, pause/resume, reset, kinematics, narrow layout and disposal pass on macOS, Android and the iOS simulator |

The package suite passes 17 tests. Its six plugin tests use a small renderer test
double to exercise lifecycle behavior, while every physics world uses native
Rapier. The app integration tests and qualification runner use actual native
renderers. Three Rust tests, strict Clippy, format checks, Dart analysis and the
workspace package-boundary check also pass.

| Platform | Build evidence | Execution evidence |
| --- | --- | --- |
| macOS arm64 | Flutter debug app and native asset built | 17 package tests, Metal native-view app integration test and render/recreation/cleanup passed |
| macOS x64 | Rust target check passed | Hardware run open |
| Android arm64 | Flutter debug APK built | Pixel 9 Pro Vulkan/shared-texture app integration test passed |
| Android armv7 and x64 | Native physics libraries packaged in the debug APK; Rust target checks passed | Hardware runs open |
| iOS simulator arm64 | Flutter debug app built | iPhone 17 Pro simulator on iOS 26.5 passed the Metal native-view integration test |
| iOS device arm64 | Unsigned Flutter debug app built; Rust target check passed | Signed hardware run open |
| iOS simulator x64 | Rust target check passed | Linked app and simulator run open |
| Linux arm64 and x64 | Rust target checks passed | Linked Flutter builds and hardware runs open |
| Windows arm64 and x64 | Rust target checks passed | Linked Flutter builds and hardware runs open |

The Metal runner saved `qualification/metal-physics.png` and
`qualification/native-physics.json` under the example. A sphere settled at
0.499931 metres above a floor with a 0.5 metre radius. The renderer produced 245
pixel colours after recreation at 640 by 400 pixels. Closing the engine and world
returned native body and world counts to zero.

The macOS app test checks desktop and 396 by 800 layouts without Flutter errors.
Manual window inspection remains blocked by the locked Mac. The dedicated CI
workflow schedules desktop tests/builds and mobile builds; it has not run remotely.
Cross-target Rust checks verify compilation without linking or executing a target
binary. Open platform rows remain qualification work, so this table does not claim
full platform rollout readiness.
