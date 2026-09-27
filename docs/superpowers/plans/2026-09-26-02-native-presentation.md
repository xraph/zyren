# 02: Native texture presentation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present native GPU frames inside Flutter without per-frame CPU pixel readback on each qualified target.

**Architecture:** Keep the backend output independent of Flutter, register native surfaces through the platform adapter and exchange opaque session keys. Retire each buffer only after producer and consumer ownership ends. Prove platform synchronization before enabling that adapter by default.

**Tech Stack:** Flutter 3.47.5 embedder APIs, Rust 1.97.1, wgpu 30.0.1, Metal/IOSurface, Android SurfaceProducer/Vulkan, DXGI/Direct3D 12.

**Spec:** [Native presentation](../../design/native-presentation.md), [API policy and lifecycle](../../design/native-3d-api.md), [program](2026-09-26-native-3d-program.md).

## Global Constraints

- Render 3D through native Metal, Vulkan or Direct3D 12. Do not add WebGL, a WebView, JavaScript or an OpenGL renderer fallback.
- Keep geospatial an optional plugin. The general 3D core must never import geospatial.
- Target general 3D capabilities comparable to Three.js; do not claim JavaScript source compatibility or current feature parity.
- Keep scene data, geometry, materials, animation and plugin contracts usable from Dart without Flutter widgets.
- Use Flutter 3.47.5 and Rust 1.97.1 for development; keep Dart SDK >=3.10.0 <4.0.0 and Flutter >=3.38.0 declarations until a tested API requires a higher floor.
- Keep wgpu pinned to 30.0.1 while introducing native texture interoperability; review unsafe HAL code before changing that pin.
- Commit each verified task locally. Do not push or merge without a request.
- Keep shipped prose free of em dashes and attribution trailers.

## Review Focus

- Flutter retains an old buffer through resize: it cannot be overwritten or freed early. Tasks 1/2/4.
- Android replaces a Surface without changing the Dart widget: discard the old native window and resume with a fresh epoch. Task 3.
- Windows producer and consumer use different adapters or incompatible handles: return an actionable incompatibility error. Task 4.
- Device loss occurs with two submitted frames and a closing view: stop publication and finish bounded teardown without waiting forever. Tasks 1/6.
- Opacity, color, clipping or orientation differs from Flutter's image composition: use an independent reference fixture. Tasks 2-6.

---

## File map and prerequisites

Start after plan 01's backend/output types. The Rust crate has moved to
`packages/zyren_native/native`. Do not create a second copy in the Flutter plugin.

| Files | Responsibility |
| --- | --- |
| `native/src/interop/{mod,session,leases,metal,android,dx12}.rs` under `zyren_native` | Native surface registry and isolated backend interop |
| `packages/zyren_native/native/include/zyren.h` | Versioned surface ABI |
| `packages/flutter_zyren/lib/src/presentation/{surface_session,native_presenter}.dart` | Flutter surface attachment and stable texture widget |
| `packages/flutter_zyren/darwin/Classes/{ZyrenTexture,ZyrenSurfaceRegistry}.{h,mm}` | Shared Apple implementation |
| `packages/flutter_zyren/{ios,macos}` | Thin plugin registration/build declarations |
| `packages/flutter_zyren/android/src/main/kotlin/dev/twinos/zyren/ZyrenPlugin.kt` | Android embedder lifecycle |
| `packages/flutter_zyren/android/src/main/cpp/zyren_surface.cpp` | JNI and native window ownership |
| `packages/flutter_zyren/windows/{zyren_plugin.cpp,zyren_surface.cpp}` | DXGI registration and handle lifetime |
| `examples/multiple_views/integration_test/presentation_test.dart` | Cross-platform composition/lifecycle workload |
| `benchmarks/presentation`, `docs/verification.md` | Measurements and actual qualification evidence |

For Rust commands below, run in `packages/zyren_native/native`. Surface tests use
the production lease state machine with deterministic completion events; platform
tests additionally use real Flutter/native consumers. A fake callback alone
cannot qualify native synchronization. GPU-to-GPU copies are permitted and counted.

## Task 1: Surface ABI, bounded leases and cancellation

**Files:** Create native `src/interop/{session,leases}.rs`,
`tests/surface_lifetime.rs`; extend `include/zyren.h`, Dart bindings and
`packages/flutter_zyren/lib/src/presentation/surface_session.dart`.

**Interfaces:** Implement `SurfaceSession`/`SurfaceKey` from the spec. Use v2 C
symbols with `fg2_` prefix and `struct_size`/`abi_version` fields. Native exports
include `fg2_runtime_token`, `fg2_surface_resize`, `fg2_surface_suspend` and
`fg2_surface_close`; each takes a validated session/surface key and returns a
status plus request-owned error output. Platform creation functions accept their
native object only inside native code. Both plugin and FFI must return the same
runtime token; a mismatch fails initialization.

Define internal Rust `LeaseLedger::new(buffer_limit: usize)`,
`acquire(epoch: u64) -> Result<LeaseId, SurfaceError>`,
`gpu_completed(LeaseId)`, `consumer_released(LeaseId)`, `retire(LeaseId)`, and
`is_reusable(LeaseId) -> bool`. `LeaseId` contains slot and generation. No method
uses a platform pointer as a slot. A ledger entry is reusable only when retired
and both completion conditions hold.

- [x] Write the production-ledger regression, including the opposite completion order:

```rust
#[test]
fn a_gpu_completion_does_not_release_a_consumer_lease() {
    let mut ledger = LeaseLedger::new(3);
    let lease = ledger.acquire(1).unwrap();
    ledger.retire(lease).unwrap();
    ledger.gpu_completed(lease).unwrap();
    assert!(!ledger.is_reusable(lease));
    ledger.consumer_released(lease).unwrap();
    assert!(ledger.is_reusable(lease));
}
```

- [x] Run `cargo test --test surface_lifetime`; expect missing ledger/ABI behavior. Add stale-generation callbacks, resize while all buffers are held, close-before-create completes, duplicate release, out-of-order frame completion and 10,000 coalesced requests. Resident allocation and pending request counts must remain bounded.
- [x] Implement the registry, lease state machine and one latest-pending-frame slot. Validate keys before touching resources. Keep obsolete epochs alive only for retirement. Separate request completion from consumer release. Use platform ownership primitives to determine consumer release, never synthetic Dart acknowledgments. For WSI swapchains, map acquire/present ownership to the same guarantees and report the actual negotiated image count.

```text
publish(frame):
  if closing or frame.epoch != current.epoch: retire without notifying Flutter
  otherwise atomically replace the published reference and notify the texture
close():
  stop acquisition; invalidate epoch; stop callbacks from initiating new work
  await producer completion or terminal device-loss result
  unregister consumer; retain outstanding native leases until actual release
```

- [ ] Add a native test proving platform registration and Dart FFI share the same runtime registry, including release packaging. Document bounded GPU-wait timeout handling: fail the session, retain unsafe-to-free native ownership until device/consumer release, report it; do not free active buffers to meet a timeout.
- [x] Run Rust unit tests, clippy and Dart surface-state tests; commit `feat: define versioned native surface ownership`.

## Task 2: Shared Metal presentation on macOS and iOS

Current checkpoint: the opt-in Apple bridge, runtime identity, direct Metal
output and actual Flutter pixel checks are implemented. Continuous rendering
fails when Flutter's Core Video cache retains all three buffers. macOS also
retains them after unregister; the iOS simulator releases them on teardown.
The adapter stays disabled by default. See the
[checkpoint](../../apple-presentation-checkpoint.md).

The original pool-based steps below are historical plan detail. Ownership probes
rejected pool availability as a completion signal; fresh allocations then exposed
the compositor-cache limit. Before proceeding with qualification, prove a
supported consumer-retirement contract. The next candidate is a CAMetalLayer
platform view with measured Flutter composition and lifecycle behavior. Keep the
current budget, and do not bypass it or use private engine selectors.


**Files:** Create native `src/interop/metal.rs`, Apple files in the file map,
`packages/flutter_zyren/test/apple_surface_contract_test.dart` and
`examples/multiple_views/integration_test/apple_presentation_test.dart`.
Modify podspec/plugin declarations and native linkage, keeping one Rust runtime.

**Interfaces:** An Objective-C++ `ZyrenTexture` implements `FlutterTexture` and
returns the latest retained completed `CVPixelBufferRef`. A native registry owns
fresh IOSurface allocations and `CVMetalTextureCache`. Rust uses the same `MTLDevice`;
all unsafe HAL imports remain inside `interop/metal.rs` with explicit retained
object, usage, device and destruction invariants.

- [ ] Add a 64x64 GPU fixture with red/green/blue/white corners, a 50% alpha edge and an opaque gray patch over Flutter checkerboard content. Define test helpers in the integration fixture: `readPresentationCounters()` reads native counters; `captureComposition()` uses Flutter integration screenshot support or a host screenshot adapter, with its own readback excluded from ordinary presentation counters.

```dart
final before = await readPresentationCounters();
await tester.pumpFrames(view, const Duration(seconds: 2));
final after = await readPresentationCounters();
expect(after.presentedFrames, greaterThan(before.presentedFrames));
expect(after.presentationReadbackBytes - before.presentationReadbackBytes, 0);
expect(after.liveSurfaces, before.liveSurfaces);
```

- [ ] Run the new integration on macOS before implementation; `requireSharedTexture` must fail visibly, not pass through RGBA fallback. Add native tests retaining one returned buffer through several subsequent frames, then releasing it, plus route removal during allocation.
- [ ] Allocate fresh IOSurface-backed buffers within the session's lease and byte budgets. The pinned Flutter importer releases CVMetalTexture before its retained MTLTexture, so pixel-buffer pool availability cannot signal consumer release. The native probe supports an IOSurface lifetime guard; prove it with Flutter before enabling presentation. Publish only after successful producer completion, take/release references under a short lock and notify on the permitted embedding thread. `copyPixelBuffer` must not wait, render or call Dart. Do not inspect retain counts.

```text
render worker: reserve lease -> allocate IOSurface -> create Metal view -> encode -> submit
completion: check Metal success and epoch -> publish retained pixel buffer -> notify
raster callback: retain published pixel buffer -> return ownership per Flutter API
detach: stop notifications -> unregister -> retire allocations/cache after outstanding use
```

- [ ] Verify resizing, odd physical sizes, opacity, rotation, clipping, two views, inactive visible macOS windows and 100 route transitions. Run macOS debug and standalone release plus iOS simulator. Run the same workload on a physical iOS device before marking iOS shared presentation qualified.
- [ ] Inspect GPU capture for no per-frame buffer mapping/CPU image upload; record copy counts and memory. Run focused tests/analyzer; commit `feat: present native Metal textures in Flutter` with unverified physical-device checks explicitly recorded if unavailable.

## Task 3: Android Vulkan SurfaceProducer integration

**Files:** Create Android Kotlin/JNI files from the map, native
`src/interop/android.rs`, `android/CMakeLists.txt` and integration tests in
`examples/multiple_views/integration_test/android_presentation_test.dart`.

**Interfaces:** Kotlin owns `TextureRegistry.SurfaceProducer` and callbacks.
JNI acquires/releases `ANativeWindow` from the current Java Surface. Rust creates
and drives the Vulkan surface without exposing pointers in Dart. The returned
Flutter texture ID and opaque renderer key refer to the same attachment.

- [ ] Write instrumentation cases that replace/revoke the Surface, rotate the device, background/resume and resize while rendering. Record `SurfaceKey` epoch and ensure no completion publishes to the old epoch. Include the corner/alpha fixture and counters from task 2.

```text
given epoch E with one submitted Vulkan frame
when onSurfaceCleanup occurs and then onSurfaceAvailable supplies a new Surface
then old ANativeWindow ownership retires after its submitted use
and E completions cannot notify the new surface
and the new epoch draws the correctly oriented four corners
```

- [ ] Run `fvm flutter devices --machine`, then `fvm flutter test integration_test/android_presentation_test.dart -d <connected-device-id>` from `examples/multiple_views`, substituting the actual listed device ID. Before the adapter lands, shared presentation must report unavailable. An emulator result does not qualify physical Vulkan behavior.
- [ ] Implement callbacks and serialize state changes through the native session. Obtain the current Surface when needed, including after size/format changes; do not cache a Java Surface forever. Set physical dimensions, account for the embedder's crop/rotation behavior and suspend when no Surface exists. Do not depend on undocumented `scheduleFrame` behavior.

```text
onSurfaceAvailable: fetch current Surface -> acquire window -> register new epoch
onSurfaceCleanup: revoke epoch -> stop acquisition -> retire and release old window
resize: set physical size -> revalidate current Surface -> reconfigure if needed
frame: acquire Vulkan surface image -> render -> present -> account submission
```

- [ ] Use capability-driven Vulkan formats/present modes and adapter limits. Confirm max frames in flight and memory remain bounded through 100 rotations/resizes and repeated navigation. Run on at least one Adreno and one Mali family device in the release qualification matrix; mark unavailable families as unverified.
- [ ] Build ARM64 debug/release, run native and Flutter integration tests on available devices, record backend/driver/API level and commit `feat: present Vulkan frames through Android surfaces`.

## Task 4: Windows DXGI sharing and synchronization proof

**Files:** Create Windows files from the map, native `src/interop/dx12.rs`,
`packages/flutter_zyren/windows/CMakeLists.txt`,
`examples/multiple_views/integration_test/windows_presentation_test.dart` and
`docs/verification/windows-interop.md`.

**Interfaces:** Register a supported GPU surface descriptor with Flutter's texture
registrar. Exchange a shared DXGI resource through native code only. Define
`DxgiBridge` with `publish(completed_frame)`, `release_consumer(frame_id)` and
`close()` internally; its implementation must establish the actual GPU ownership
protocol before `consumer_released` can be signalled to the ledger.

- [ ] Create a minimal native proof that draws the four-color fixture with D3D12 and imports it into Flutter, recording producer/consumer adapter LUID, format, shared-handle type and synchronization primitives. Intentionally test incompatible adapters and stale/closed handles; these return labeled errors without device removal or a process crash.

```text
given a buffer still sampled by the Flutter compositor
when the producer wants to reuse its shared resource
then the producer waits on the documented consumer ownership/fence condition
and no Dart notification or descriptor-release callback is treated as GPU completion
```

- [ ] Run that proof on a Windows host with graphics diagnostics enabled. The initial expected result is an unavailable adapter or a failed proof until a synchronization path is demonstrated. Write the selected D3D12/D3D11 interop path and ownership evidence in `windows-interop.md`; use a native D3D11 bridge only if Flutter's import requires it, while 3D rendering remains D3D12.
- [ ] Implement shared-resource allocation, matching-adapter checks, handle duplication/closure and the proven fence/ownership sequence. A GPU copy into a compatible shared target is acceptable. Isolate unsafe HAL code and verify resource state transitions around external ownership.

```text
allocate: match adapter -> create shareable target -> import compatible consumer view
publish: finish D3D12 writes -> transfer ownership -> register completed descriptor
retire: wait for actual consumer completion -> close owned handles after last use
incompatibility: report presentationUnavailable with adapter/format reason
```

- [ ] Run resize, minimization, monitor/DPI change, two views, background/foreground and standalone release. Exercise integrated and discrete adapters in qualification. If the proof cannot establish safe reuse, do not enable or stub the adapter; document the failed experiment and keep Windows shared presentation a release blocker.
- [ ] Run Windows native/widget/integration checks and commit the verified proof/adapter as a focused change, with its actual support status in `docs/verification.md`.

## Task 5: Linux feasibility and honest fallback policy

**Files:** Create `docs/verification/linux-presentation.md`, a Vulkan embedder
proof under `experiments/linux_presentation`, and only if qualified, native/plugin
adapter files under `packages/flutter_zyren/linux` and `native/src/interop/linux.rs`.
Add Linux cases to `packages/flutter_zyren/test/presentation_policy_test.dart`.

**Interfaces:** Retain the same `SurfaceSession` API. No new OpenGL 3D backend or
public OS-specific application API. `requireSharedTexture` fails if no compatible
GPU presentation contract exists. `readbackOnly` remains an explicit diagnostic
mode. Linux support is experimental until its native GPU path passes qualification.

- [ ] Pin the policy regression:

```text
given Vulkan rendering is available but compositor interoperability is not
requireSharedTexture -> presentationUnavailable, zero submitted readback frames
allowReadback -> readback in RendererInfo, counted readback bytes
readbackOnly -> readback in RendererInfo even if a GPU bridge is installed
```

- [ ] Run the policy widget tests; a Vulkan backend flag must not be enough to select shared presentation. Inspect the pinned Linux embedder for a supported Vulkan/external-memory route. Record whether any bridge requires compositor-side GL and whether that fits the stated native-only constraint before proposing it; do not interpret the library constraint as authorization for a new renderer fallback.
- [ ] Build the smallest feasible Vulkan-to-compositor proof with the task 2 fixture and lease counters. If the public embedder cannot supply a supported path, record the exact missing capability and leave the adapter absent. Keep the primary iOS/Android/macOS/Windows delivery independent of this spike.
- [ ] Verify the Linux build and explicit readback diagnostic behavior on a Linux host. A future embedder enhancement needs a separate reviewed design. Commit `docs: record Linux native presentation qualification` or a proven adapter with its runtime tests.

## Task 6: Flutter composition, capture, recovery and measurements

**Files:** Modify facade presenter/controller and native diagnostics; create
`examples/multiple_views/integration_test/presentation_test.dart`,
`packages/flutter_zyren/test/capture_lifetime_test.dart`,
`benchmarks/presentation/{README.md,lib/main.dart}` and
`docs/verification/presentation-results.md`.

**Interfaces:** Implement `SceneController.capture(CaptureOptions) -> Future<ImageData>`
using an explicit readback target. `CaptureOptions` fixes physical dimensions,
color space and alpha policy. Shared rendering returns `PresentedOutput` and
`FrameStats` only. Recovery uses new device/surface generations and the spec's
manual/automatic-once policy; no endless retries.

- [ ] Write integration fixtures for Flutter clip/transform/opacity/scroll/overlay behavior, route disposal during capture and loss with two in-flight frames. Use fault injection at the native session boundary for deterministic device loss, plus actual background/foreground tests on mobile.

```text
capture in flight + controller dispose:
  capture completes once with a typed cancellation/disposed result
  buffers retire after their producer use; whenDisposed eventually completes
device lost + automaticOnce:
  first loss produces a new generation and reuploads retained CPU resources
  a failed recreation ends in SceneFailed with retry available
  callbacks from the old generation never change the new texture
```

- [ ] Run `fvm flutter test test/capture_lifetime_test.dart` in the facade and the integration on each available host/device. Ensure these tests fail before capture/generation cleanup is implemented.
- [ ] Implement capture as a separately budgeted request, state recovery and throttled statistics. Remove ordinary RGBA creation from the shared presenter. Keep compatibility readback behavior in an explicit adapter, never in the default path. Suspend when hidden, retain correct visible/inactive behavior and avoid rendering at unbounded widget rebuild rates.
- [ ] Benchmark the existing mesh, two-view and procedural-globe workloads for at least 300 measured frames after warm-up. Record device/OS/build configuration, p50/p95/p99, upload/readback/GPU-copy counts, memory and coalesced frames. Capture traces proving the presentation path has no CPU pixel readback. Plan 04 task 5 adds the model/instancing workloads after plan 03 implements them; their absence must not block the first presentation proof.
- [ ] Run all affected tests, clippy, analyzer and standalone release launches. Update the platform matrix with build, runtime, shared presentation and physical-device columns separately; commit `test: qualify native presentation lifecycle and performance`.

## Exit gate

The primary platform claim requires four qualified native presentation adapters,
not one working Apple path and three cross-compiles. Device access can block
qualification without blocking unrelated core work. Record that distinction in
the matrix; keep an unverified adapter out of the supported-platform claim.
