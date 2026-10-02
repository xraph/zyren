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
| Snapshots and renderer recovery | Implemented; deterministic replay, stale-handle rejection, failed attachment recovery and native Metal/Vulkan/DX12 renderer recreation |
| Debug geometry | Implemented; collider, joint and contact geometry appears in the saved native renders |
| Physics Lab | Implemented; controls, pause/resume, reset, kinematics, narrow layout and disposal pass on macOS arm64, Pixel arm64, an Android x64 emulator, the arm64 iOS simulator, Linux arm64/x64 and Windows arm64/x64 |

The package suite passes 17 tests on all six hosted desktop architectures. Its
six plugin tests use a small renderer test
double to exercise lifecycle behavior, while every physics world uses native
Rapier. The app integration tests and qualification runner use actual native
renderers. Three Rust tests, strict Clippy, format checks, Dart analysis and the
workspace package-boundary check also pass.

| Platform | Build evidence | Execution evidence |
| --- | --- | --- |
| macOS arm64 | Flutter debug app and native asset built | 17 package tests, Metal native-view app integration test and render/recreation/cleanup passed |
| macOS x64 | Flutter debug app linked; x86_64 slices verified locally and hosted app built | 17 package tests and native Metal render/recreation/cleanup passed; app integration failed on a GPU completion timeout after resume |
| Android arm64 | Flutter debug APK built | Pixel 9 Pro Vulkan/shared-texture app integration test passed |
| Android armv7 | Native physics library packaged in the debug APK; Rust target check passed | Hardware run open |
| Android x64 | Native physics library packaged; Rust target check and dedicated integration APK build passed | Vulkan/sharedTexture integration passed with SwiftShader when replaying the saved APK; a prior emulator service loss did not recur |
| iOS simulator arm64 | Flutter debug app built | iPhone 17 Pro simulator on iOS 26.5 passed the Metal native-view integration test |
| iOS device arm64 | Signed Flutter debug app built and installed on iPhone 16 Pro | Integration blocked by wireless debugger discovery; signed execution remains unverified |
| iOS simulator x64 | Local Flutter debug app linked and x86_64 slices verified; hosted Xcode build finished | Hosted simulator booted, but Flutter returned no integration result before the 60-minute job timeout; execution remains unverified |
| Linux arm64 | Flutter debug app linked in Debian 12 container and Ubuntu CI | 17 package tests, Vulkan/readback app integration and native render/recreation/cleanup passed locally and on a native arm64 CI host; physical GPU run open |
| Linux x64 | Flutter debug app linked in emulated Debian 12 container and Ubuntu CI | 17 package tests, Vulkan/readback app integration and native render/recreation/cleanup passed locally and on an x64 CI host; physical GPU run open |
| Windows arm64 and x64 | Flutter debug apps linked on native-architecture hosted runners | 17 package tests, DX12/readback app integration and native render/recreation/cleanup passed on both architectures |

The Metal runner saved `qualification/metal-physics.png` and
`qualification/native-physics.json` under the example. A sphere settled at
0.499931 metres above a floor with a 0.5 metre radius. The renderer produced 245
pixel colours after recreation at 640 by 400 pixels. Closing the engine and world
returned native body and world counts to zero.

The macOS app test checks desktop and 396 by 800 layouts without Flutter errors.
Manual desktop inspection passed, including ball creation, queries and pause/resume.
Manual narrow inspection remains unverified because the capture tool kept returning
the desktop window size. The dedicated CI workflow ran arm64/x64 desktop builds,
native rendering, app integration and mobile builds. Five desktop jobs and the
mobile build job passed; Intel macOS app integration failed on GPU completion
after resume, including its retry with a bounded native-frame wait. Hosted
renderer evidence identifies the backend, not
the physical GPU model. Separate repository-wide checks failed formatting outside
physics; their mobile build passed on retry after an initial Rust download timeout.
Repository-wide CI is not green.
Cross-target Rust checks verify compilation without linking or executing a target
binary. Open platform rows remain qualification work, so this table does not claim
full platform rollout readiness.

You can find the rerun evidence and remaining blockers in the
[2026-10-02 qualification record](../../examples/physics_lab/qualification/2026-10-02/README.md).
