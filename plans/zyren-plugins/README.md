# Zyren plugin expansion

You can follow all 11 workstreams through nine chats. Eight have dedicated owners.
Configurator, spatial audio and capture share one chat and run in sequence.
This plan starts implementation; it does not mark any proposed package complete.

## Workstreams and ownership

| ID | Chat scope | Owned package directories | First useful implementation | Later milestones |
| --- | --- | --- | --- | --- |
| 01 | Asset pipeline | packages/zyren_pipeline | Validate and build a versioned asset bundle, preserve source IDs, and load it through current asset services with cache invalidation tests | Incremental builds, mesh optimization, LOD generation, texture preparation, offline cache budgets |
| 02 | Interaction | packages/zyren_interaction | Object event dispatch, hover and pointer capture with removal/disposal tests and a compact Flutter example | Gesture arbitration, keyboard focus, semantics, anchored labels, widget surfaces |
| 03 | Configurator, in smaller-plugin batch | packages/zyren_configurator | Validate options, apply material/component selections, and save/restore configuration by stable IDs | Imported material variants, camera presets, hotspots, application catalog hooks |
| 04 | Native XR | packages/zyren_xr | Inspect native camera/presentation requirements, implement a real platform session slice, and report device capability and tracking failures | ARKit/ARCore tracking, anchors, planes, depth occlusion, lighting, then headset adapters |
| 05 | Reality capture | packages/zyren_pointclouds and packages/zyren_splats | A bounded point-cloud import/render/pick path plus a separate first splat rendering slice if current GPU APIs permit it | Spatial streaming and LOD, classifications, clipping, LAS/LAZ/E57 adapters, splat sorting and memory budgets |
| 06 | Characters and navigation | packages/zyren_characters and packages/zyren_navigation | Animation state transitions plus path queries on a small navigation mesh, integrated with existing animation and physics | Root motion, character controller, obstacle handling, retargeting, IK, navmesh generation |
| 07 | Spatial audio, in smaller-plugin batch | packages/zyren_audio | A real native audio backend with scene emitter/listener transforms, attenuation and lifecycle handling | Occlusion, streaming, timeline synchronization, additional backend adapters |
| 08 | Scientific visualization | packages/zyren_scientific | Validated scalar data, transfer mapping, a slice or surface visualization and a reproducible numerical fixture | Isosurfaces, vector fields, streamlines, temporal data and native volume rendering |
| 09 | Collaboration | packages/zyren_collaboration | Versioned scene operations with stable IDs, two-client conflict tests and a local shared scene example | Presence, camera sharing, permission hooks, persistence, offline reconciliation |
| 10 | Studio | packages/zyren_studio and examples/studio | Compose existing tools and inspector into a compact editor with a versioned saved document and a working reload path | Prefabs, asset diagnostics, animation authoring, material editing, live preview |
| 11 | Capture, in smaller-plugin batch | packages/zyren_capture | A deterministic still/turntable image sequence using real capture capabilities, cancellation and cleanup | High-resolution output, alpha, video encoding and depth/object-ID passes where supported |

Each owner may add an example under its own package. Only Studio owns
examples/studio. Each chat owns its corresponding plan file in this directory:
pipeline.md, interaction.md, xr.md, reality-capture.md, characters-navigation.md,
scientific.md, collaboration.md, studio.md, or smaller-plugins.md.

The dispatch chat owns this README and chats.json. Do not rewrite another
owner's plan, package or example.

## Start and implementation sequence

Start each chat with repository reconnaissance. Check package exports, tests and
native capabilities before designing interfaces. The root README may lag behind
package implementation. Record the existing APIs you will reuse, decisions,
dependencies, acceptance checks and unresolved requirements in your owned plan.

Then implement a useful first slice. Continue through its relevant checks and
make a focused local commit. A skeleton, mock backend or plan alone does not
establish runtime support. If hardware prevents a live check, finish the work
you can verify and record the exact remaining device check.

The smaller-plugin chat plans all three packages first, then implements
configurator, audio and capture in that order. Keep separate acceptance criteria
and commits for each. A blocked backend in one package must not prevent useful
work on the others.

Pipeline and interaction provide shared foundations, but the other chats can
start against existing APIs. Avoid speculative dependencies on unfinished
packages. Add integration adapters after their public interfaces exist.

## Shared architecture

Rendering remains native Metal, Vulkan or DX12. Do not introduce WebGL, OpenGL,
WebView or browser rendering fallbacks. Keep the general-purpose Dart core
independent of Flutter and domain plugins. Geospatial remains optional.

Reuse the scene graph, asset services, resource ownership, frame demand, timeline,
physics, tools and diagnostics. Prefer optional adapters between plugins.
Preserve source identities through import, caching, saved scenes and collaboration.
Do not put application credentials, catalog pricing or authorization policy into
the renderer.

XR camera textures, external render targets, splat rendering and volume resources
may require native changes. Describe those changes explicitly. Mock session data
does not count as AR, and a mesh preview does not count as a splat renderer.

Engineering already has shared review and persistence machinery. Collaboration
must inspect it before defining another protocol. Studio must reuse current
tools and inspector APIs. Character work must build on existing imported
animation and timeline mixing.

## Concurrent checkout rules

All nine chats use the current local checkout and branch. Do not switch branches
or create a branch containing codex. Other work is active here. Do not revert,
format broadly, stage, or commit another chat's edits.

At dispatch, another chat owns the declarative Flutter API under
packages/flutter_zyren/lib/src/declarative, its facade export, tests and related
example. That chat is "Find a React Three Fiber alternative",
ID 01a0fe52-c06f-7781-9c98-68ac4643d58d. Treat those files as externally owned.
Native qualification and geospatial work are also active. Read current status
before every shared edit.

Keep most edits inside your owned paths. For an existing shared file, write a
short request in your own plan naming the path, required API and compatibility
impact. Check other program plans for overlapping requests before proceeding.
You may make a minimal compatible shared change when no owner is editing it;
do not overwrite active work. When a shared change is blocked, continue work in
your owned paths and record the dependency.

Serialize shared-file edits, workspace registration, dependency resolution and
Git index operations with an atomic directory lock at
/tmp/zyren-plugin-expansion.lock. Use mkdir to acquire it, record your chat ID
and PID inside, and release only your own lock in a finally block or shell trap.
Check ownership when busy. Never delete a foreign lock merely because it is old.
Keep the lock brief; do not hold it across long tests or GPU builds. Use --no-pub
for Flutter checks after dependency resolution where applicable.

While holding the lock, re-read shared files, preserve other entries, inspect
git status and staged changes, and apply only your owned changes. Other existing
chats may not use this lock, so also check for concurrent edits before committing.
If another chat has staged work, leave it untouched and defer your commit until
you can isolate your changes. Do not use git add . or git add -A.

Commit coherent checked changes locally. Never push or merge without a request.
Do not add co-author trailers or agent attribution. Use rex-voice before drafting
repository prose or commit message bodies, then humanizer in embedded mode.
The skills are available at /Users/rexraphael/.agents/skills/rex-voice/SKILL.md
and /Users/rexraphael/.agents/skills/humanizer/SKILL.md. Use no em dashes.

## Verification and evidence

Record implementation, automated checks and live device checks separately.
A passing unit test does not establish native presentation or integration.
Use representative assets, bounded memory, failure/cancellation tests and
deterministic fixtures where appropriate. Record numerical error for scientific
and geometric operations. Do not claim measurement accuracy from splat imagery.

Keep product layouts compact. Use the shared ZeroState for empty states, with
distinct loading, denial and failure handling. Check desktop and narrow widths.
Only expose walkthrough controls for registered walkthroughs that actually start.

Use private test outputs per workstream. Do not compete for a connected device
or change another running application's session. Record device occupancy and
continue CPU work when hardware is busy. Backend availability is separate from
device qualification.

Each owned plan should end with the current commit IDs, tests, live checks,
remaining scope and blockers. Keep a clear distinction between a working first
slice, a complete plugin and a package published to pub.dev.
