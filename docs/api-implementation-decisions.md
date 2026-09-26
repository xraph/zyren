# API implementation decisions

These decisions apply to the API milestone on `dart-core-api`. They keep the
current API usable while the renderer and presentation milestones are built.
The primary limits are explicit readback, immutable geometry and deferred asset
loaders. The full plan remains the source of future scope.

- Task 1: Ruling: core SceneEngine requires an explicit RendererFactory. The Flutter facade retains a small delegating SceneEngine with the native default, preserving existing Flutter callers without a core dependency on native code.
- Task 1: Ruling: the sample snapshot test needs the existing required aspect argument; use snapshot(camera, 1).
- Task 1: Ruling: keep Rust crate name, header and ABI v1 intact during relocation. Changing the package asset URI is necessary; renderer algorithms must remain byte-for-byte unchanged.
- Task 1 Ruling: Dart test compiles suites separately and did not carry the driver -D flag. GPU suites now also accept RUN_NATIVE_GPU=1 from the process environment; the skipped run is not verification.
- Task 1 Ruling: NativeBackend and the legacy NativeRenderer share the existing worker packet path during extraction. GPU timestamps and total residency are unavailable, so statistics report null instead of fabricated zero.
- Task 1: complete at 16f6616. Final verification: 25 Dart, 10 widget, 2 native GPU, 3 Rust tests passed; analyzer, formatting, clippy, boundary guard, macOS integration and release passed. Physical mobile and Windows/Linux remain unverified. Ruling: reuse completed final verification rather than repeat unchanged suites for ledger bookkeeping.
- Task 2 Ruling: all scene angles, including camera fieldOfView, now use radians; migrate the planet's 42 degrees explicitly. Geodetic degrees constructors remain unchanged.
- Task 2 Ruling: revision streams coalesce synchronous edits in a microtask; revision values update immediately. This permits reentrant listener edits without broadcast-stream reentrancy errors.
- Task 2 Ruling: immutable geometry sharing is verified here; dynamic attribute updates belong to plan 03 resource work. Controller integration consumes the scheduler in task 3; the legacy viewport remains unchanged in this commit.
- Task 2 Ruling: vector_math quaternion vector rotation uses the opposite direction to its rotation matrix; use its matrix path so Quat.rotate agrees with scene composition. Positive-Z rotation regression caught this and passed after repair.
- Task 3 Ruling: define EngineOptions, RendererInfo and explicit readback policy with controllers because readiness requires them; input and expanded policy coverage stay in task 4.
- Task 3 Ruling: preserve the core plugin engine through one backend adapter. Camera is now an abstract core contract; the alpha engine camera setter propagates replacement to plugin contexts. No duplicate viewport state machine.
- Task 3 Ruling: add plugin invalidate and removable frame demand to wire optional globe controls to on-demand rendering. Headless explicit renders retain no-op demand callbacks.
- Task 3 Ruling: replace SceneView(scene:,camera:) with SceneView.scene and migrate its existing regression fixtures through backend injection. Late cancelled creation now closes the backend without attaching plugins or creating a presenter.
- Task 4 Ruling: keep unavailable adapter/driver identity null rather than repeating the backend name as invented hardware information. Presentation path remains separately reported.
- Task 4 Ruling: no shared-surface adapter exists yet, so requireSharedTexture rejects even if a custom backend advertises a shared GPU feature. AllowReadback/readbackOnly explicitly choose readback; actual platform surface factories land with plan 02.
- Task 4 Ruling: globe controls now register scale/scroll interests and listen through InputSource. The planet no longer needs parallel Listener/GestureDetector wrappers. Core headless calls still work with no input source.
- Task 5 Ruling: AssetScope.keep owns tasks supplied by loaders/extensions. AssetRequest/source resolution and AssetScope.load stay in plan 03; no callable placeholder exported.
- Task 5 Ruling: worker sessions share one response/exit/error port, preserving reply-before-exit ordering. Generation plus monotonic IDs reject stale/duplicate replies. Internal additive fg_live_renderer_count verifies NativeFinalizer fallback without exposing pointers.
- Task 5 Ruling: executable-example tests live in examples/multiple_views/test, avoiding a reverse dev dependency from the facade onto an application. CI runs them alongside the facade suite.
- Task 5: complete at 1102442. 42 Dart, 33 facade widget, 3 executable-example widget, 6 native (3 protocol and 3 real GPU), 3 Rust (GPU explicitly enabled), both macOS integrations, analyzer, format, Clippy and import boundaries passed. Ruling: reuse the just-completed suites for bookkeeping; no production changes followed those results.
- Final integration ruling: keep this named branch and managed worktree locally, following the user's no-push/no-merge rule. No integration permission menu is needed because that preference is already explicit.
- Final: Ruling: shared textures/loaders/resource scopes/PBR/picking stay in their explicit later milestones; current examples and capabilities do not claim them. Cost if wrong: clients must wait for or supply extensions.
- Final: Ruling: PerspectiveCamera remains world-space position/target/up based. Document inherited parent/quaternion transform limitations until plan 03 camera work. Cost if wrong: callers using generic Object3D camera rotation need migration.
- Final: Ruling: bounded native GPU polling remains in the presentation milestone; worker exit is handled now, an unresponsive driver remains a qualification limit. Cost if wrong: teardown can wait on a driver stall.
- Final: Ruling: platform runtime qualification and Flutter 3.38 floor remain explicit unverified gates. Refreshed iOS simulator and Android ARM64 builds passed, but no new device runtime claim follows. Cost if wrong: host-specific failures remain possible.
- Final: Ruling: one submitted frame respects maxFramesInFlight as an upper bound; broader concurrency belongs to presentation. Cost if wrong: current throughput is lower than later multi-buffer presentation.

Changing these choices requires migration tests. Shared textures replace the
current presenter path; resource handles extend immutable geometry; typed source
requests extend AssetScope. Current examples choose readback explicitly and avoid
APIs that have not been implemented.

The independent review found three defects, all fixed with regressions: stream
cancellation ownership, live engine lifetime closure and rounded-timestamp frame
pacing. There were no separate minor findings to defer.
