# Native Dart 3D implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a general native Dart 3D library with a practical Flutter API and an optional geospatial plugin.

**Architecture:** Separate the Dart scene/API layer, native Rust backend and Flutter presentation adapter. Build native texture presentation and a public resource/render-graph API before porting atmosphere or clouds. Keep one scene/ownership model across the simple and advanced APIs.

**Tech Stack:** Dart, Flutter 3.47.5, Rust 1.97.1, wgpu 30.0.1; native Metal, Vulkan and Direct3D 12.

**Spec:** [Public API design](../../design/native-3d-api.md), [native presentation contract](../../design/native-presentation.md).

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

- A route closes during GPU startup or asset decode: settle all futures, release late resources and never publish to a detached view. Plans 01 tasks 3/5 and 02 task 1.
- A compositor retains a buffer through resize or device loss: wait for the real producer/consumer retirement condition. Plan 02 tasks 1-4.
- A developer mutates nested scene values in on-demand mode: produce a frame without requiring undocumented invalidation calls. Plan 01 task 2.
- One of two users cancels a shared model load: keep the other user's decode and resources valid. Plan 03 task 3.
- Planetary plugins need unsupported formats or mobile GPU features: negotiate explicitly and never import private native renderer code. Plan 03 task 4 and plan 04 tasks 3/4.

---

## Starting baseline, 26 September

The repository is an unpublished 0.1.0 alpha. It has native opaque mesh rendering,
a perspective camera, scene transforms, a plugin dependency/service host, RGBA
presentation, geodetic maths and a procedural globe. macOS debug/release and an
iOS simulator have run; Android ARM64 has built. Windows/Linux runtime support,
physical mobile device behavior and production performance remain unverified.

Plan 01 task 1 has now extracted `gpu3d` and `gpu3d_native`, made geospatial
Dart-only and added immutable backend submissions with explicit readback output.
The existing Flutter API is preserved through the facade. M0 still needs the
controller, observable values, typed input and scoped-work tasks.

The legacy `RenderedFrame` requires RGBA bytes, Rust has one opaque pipeline,
scene snapshots serialize geometry as JSON and geometry has no textures/UVs.
Changing only the Flutter image widget cannot deliver shared native textures.
These limitations determine the first milestones.

## Delivery sequence

| Milestone | Working deliverable | Plan | Depends on |
| --- | --- | --- | --- |
| M0 | Pure Dart core, managed/borrowed Flutter controllers, stable ownership and errors | [01: API and DX](2026-09-26-01-api-and-dx.md) | Baseline |
| M1 | Shared-texture macOS/iOS viewport; qualified Android/Windows adapters | [02: native presentation](2026-09-26-02-native-presentation.md) | M0 backend/output contracts |
| M2 | Typed native resources, binary uploads, textured glTF viewer, graph/shader plugin API | [03: resources and renderer](2026-09-26-03-resources-and-renderer.md) tasks 1-4 | M0; presentation can be qualified alongside it |
| M3 | PBR, lights/shadows, interaction, instancing, animation and postprocessing | [03](2026-09-26-03-resources-and-renderer.md) tasks 5-8 | M2 |
| M4 | Geospatial tiling/streaming, depth strategy, atmosphere and clouds through public APIs | [04: geospatial and release](2026-09-26-04-geospatial-and-release.md) tasks 1-4 | M2 for streaming; M3 for atmosphere/clouds |
| M5 | Host/device qualification, benchmarks, executable docs and a versioned release | [04](2026-09-26-04-geospatial-and-release.md) tasks 5/6 | Relevant earlier feature gates |

M2's first textured glTF viewer uses an explicitly selected unlit diagnostic mode
until M3 qualifies standard PBR materials. Loading geometry does not establish
faithful glTF shading.

M1 and M2 have independent implementation portions, but the output, handle and
scope contracts must agree before either adds platform code. Complete the Apple
presentation proof early. Android and Windows proofs must start before we freeze
the surface ABI, so an Apple-only ownership assumption cannot become a public API.

Do not assign calendar promises before those interop proofs. Each plan ends with
working examples and a reviewable commit. Detailed implementation steps belong
to the linked subsystem plan, not to a single unreviewable engine rewrite.

## File and responsibility map

| Area | Main target paths |
| --- | --- |
| Dart core | `packages/gpu3d/lib/src/{math,scene,geometry,materials,resources,assets,animation,rendering,plugins}` |
| Native facade and ABI | `packages/gpu3d_native/lib/src/{backend,bindings,worker}.dart`, `hook/build.dart`, `native/include/gpu3d.h` |
| Rust renderer | `packages/gpu3d_native/native/src/{device,resources,scene,render_graph,passes,interop,diagnostics}` |
| Flutter lifecycle/input | `packages/flutter_gpu3d/lib/src/{controller,viewport,input,presentation,diagnostics}` |
| Apple presentation | `packages/flutter_gpu3d/darwin/Classes`, thin `ios`/`macos` registration |
| Android presentation | `packages/flutter_gpu3d/android/src/main/{kotlin/dev/twinos/gpu3d,cpp}` |
| Windows/Linux presentation | `packages/flutter_gpu3d/windows`, `packages/flutter_gpu3d/linux` |
| Optional glTF loader | `packages/gpu3d_gltf/lib/src/{request,decoder,extensions}` |
| Geospatial plugin | `packages/flutter_geospatial/lib/src/{geodesy,tiling,streaming,terrain,atmosphere,clouds}` |
| Runnable examples | `examples/{planet,model_viewer,shader_lab,multiple_views}` |
| Qualification | `benchmarks`, `test_assets`, `.github/workflows`, `docs/verification.md` |

The native crate move happens once in plan 01. All later paths refer to its new
location. Use focused modules with clear responsibilities; a resource registry
must not also contain platform window registration or glTF parsing.

## Definition of done for each task

- [ ] Public contracts and ownership match the design, or the same change records a deliberate design revision.
- [ ] Tests cover a user-visible result or a lifecycle/resource failure, rather than merely asserting that a method was called.
- [ ] A working example exercises the new capability through public imports.
- [ ] Error, cancellation, resize and disposal paths relevant to that task have been exercised.
- [ ] Analyze/format and the affected native checks pass; untested host/device paths are recorded explicitly.
- [ ] Review the branch, concurrent edits and staged diff; stage owned files explicitly and create a focused local commit.

Do not add production stubs for future capabilities. A planned shader, loader or
platform adapter is absent until its implementation and acceptance evidence land.

## Compatibility and release policy

0.2 establishes the controller, scene-value and backend contracts. Migrate the
planet example with each API change and retain a narrow `SceneView.scene` bridge.
0.3 delivers the model viewer and advanced shader/resource contracts. These are
scope labels, not release dates. The 1.0 gate is a documented capability profile,
qualified platforms and stable ownership semantics; it must not imply every
Three.js addon has been ported.

Publish a feature matrix separately from a platform matrix. A feature can be
implemented yet unavailable on a device, and a platform can build while a feature
fails its rendering fixture. The four primary native targets cannot be called
supported until their physical/host runtime gates pass. Linux stays experimental
until its Vulkan presentation path is qualified.

## DX acceptance workflow

Use actual consumers to review each milestone:

1. Build a spinning mesh with one import and a managed viewport.
2. Build a static viewer that uses no frames while idle, then updates immediately when a transform changes.
3. Load a glTF with visible progress, cancellation and retry; enter/leave its route repeatedly.
4. Select an object under Flutter overlays and control it from an ordinary inspector panel.
5. Add a shader effect from a separate package using only the advanced public API.
6. Add the geospatial package, change the world model and stream a deterministic terrain fixture.
7. Show the same CPU scene in two viewports with independent cameras; remove either one.
8. Launch a release app independently of the development runner on each qualified platform.

Measure setup friction as well as rendering: list manual platform edits, imports,
required generated code and cleanup actions. The first example should need none
of the first two kinds of platform-specific setup. Initial development may require
Rust through rustup, as it does today. Publishing prebuilt native artifacts needs
checksums, architecture coverage and reproducible provenance before removing that
consumer prerequisite.

## Risks that can change the sequence

Native texture interoperability is the largest early uncertainty, especially
Windows synchronization and Linux's compositor contract. If a proposed path fails,
record the rejected experiment and an alternative proof with the same API. Do not
rewrite application APIs to expose that platform's handles.

An atmosphere/cloud port depends on float textures, depth reconstruction, compute,
HDR and temporal history. A visual globe does not establish any of those. The
reference inventory in `docs/geospatial-port.md` stays the source of port scope;
3D Tiles is a separate streaming extension and does not silently expand the
supplied library's parity claim.

The scene/math migration is intentionally early because observable mutation affects
render scheduling, input, animation and asset instances. The core must become
independent of Flutter before adding a larger domain plugin surface.

## Requirement coverage

The self-review maps every API section to an implementation owner. These are
planned responsibilities; none of the unchecked steps is evidence of a feature
already working.

| Design requirement | Implementation owner |
| --- | --- |
| Native-only backends and package boundaries | Plan 01 task 1; plan 02 tasks 1-5 |
| Managed/borrowed views, rebuilds and readiness | Plan 01 task 3 |
| Immutable values, transform observability and frame demand | Plan 01 task 2 |
| Input, typed capabilities, errors and custom backend injection | Plan 01 tasks 3/4; plan 02 task 6 |
| Scoped ownership, worker death and cancellation | Plan 01 task 5; plan 03 tasks 1/3 |
| Resources, textures, asset sources and model instances | Plan 03 tasks 1-3 |
| Public plugin shaders, render graph and recoverable resources | Plan 03 task 4; plan 02 task 6 |
| Materials, lights, animation, picking and controls | Plan 03 tasks 5-7 |
| HDR, history and optional inspector | Plan 03 tasks 7/8 |
| Optional geospatial, depth, atmosphere and clouds | Plan 04 tasks 1-4 |
| Executable examples, platform evidence and packaging | Plan 04 tasks 5/6 |
| Alpha migration and compatibility | Each API-changing task; plan 04 task 6 |

## API implementation checkpoint, 28 September

Plan 01 tasks 1 through 5 are implemented: independent Dart core, observable
values, managed/borrowed controllers, typed input and policies, scoped work,
worker failure handling and executable examples. M0 passes the local macOS gate.
M1 has opt-in Metal and Android Vulkan view presentation, with broader platform
qualification still open. M2 now has explicit scoped buffer/texture allocation
and binary transfers, tested on macOS Metal and physical Android Vulkan. Scene
geometry now uses the same registry with binary transfers and changed mesh
records. Shared readback views pass lifetime and upload-reuse checks on Metal
and the physical Pixel's Vulkan backend. Textures, bounded PNG/JPEG decoding,
generated mips, dynamic geometry, alpha/depth state and object ordering now use
the native registry. Portable lines/points add physical pixel and world sizes.
Public native presenters still own separate devices. Plan 03 now implements
glTF loading, standard PBR, lights/shadows/environment, public shader and graph
plugins, instancing, skinning/morphs, animation, camera interaction, picking,
inspection, HDR tone mapping, bloom and spatial/MSAA antialiasing. Procedural
surfaces and sampled Bézier/Catmull-Rom paths extend the general-purpose core.
The [renderer profiles](../../renderer-capabilities.md) list tested behavior and
the remaining Three.js breadth. Geospatial parity and release qualification stay
in plan 04; neither is implied by the core implementation checkpoint.

The four subsystem plans contain 25 task groups and explicit verification steps.
Advanced material/loader extensions remain a named capability backlog until
their own fixtures and implementation land. Do not expand a task's claim beyond
the behavior its tests and native evidence establish.
