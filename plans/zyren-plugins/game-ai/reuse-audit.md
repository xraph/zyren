# Existing plugin reuse audit

The game and AI plan extends the current plugins. You should not need a second
prefab system, input router, asset cache, editor shell or assistant client to
build a game. The tasks now state which existing APIs they consume and where
the missing behavior belongs.

Audit date: 2026-10-03. We inventoried the 30 top-level package manifests and
reviewed source and relevant test cases for overlapping features. The shared
`main` checkout changed during review; `6fa3f054` was the last observed commit
before plan edits. `examples/studio/lib/studio_workspace.dart` was concurrent
untracked work when inspected. This is a source review, not a test run or a
platform qualification. No implementation files were changed for this audit.

## Corrections applied to the plan

| Potential duplication | Existing source and boundary | Revised tasks |
| --- | --- | --- |
| Authored `GamePrefab` format and expansion | [Studio authoring](../../../packages/zyren_studio/lib/src/authoring.dart) already creates prefabs. [Document](../../../packages/zyren_studio/lib/src/document.dart) resolves `expandedNodes` and `prefabOwners`. | G1 uses flat `GameSpawnTemplate` runtime recipes. G7 compiles existing Studio prefab expansion; S1/S3 extend component references and overrides in the same document/history. |
| `GameInputRouter` with its own pointer ownership | [InputRouter](../../../packages/zyren/lib/src/input/input_router.dart) already arbitrates registered consumers and supports blocking/cancellation. Interaction adds object capture and focus. | G3 adds `GameActionState` for actions, rebinding and device state. It registers with the existing router and focus scopes. |
| New game viewport and scene lifecycle | [Flutter scene widgets](../../../packages/flutter_zyren/README.md) already provide `SceneCanvas`, `SceneView`, declarative nodes, scene selectors and an asset cache. | G3 provides `GameSceneBinding` and HUD state; it composes those widgets and the interaction overlay. |
| Rebuilt character motor, animation or camera navigation | [Characters](../../../packages/zyren_characters/README.md) owns root motion, motor, IK, retargeting and animation transitions. Core supplies orbit/fly/trackball controls and framing. | G4 adds game intent, possession integration, follow/chase constraints and camera collision. Existing perspective/orthographic transitions are not a generic camera pose blend. |
| Separate game bundle format, cache and build service | [Pipeline bundle](../../../packages/zyren_pipeline/lib/src/bundle.dart), [build runtime](../../../packages/zyren_pipeline/lib/src/build_runtime.dart) and [Studio adapter](../../../packages/zyren_pipeline/lib/studio.dart) already cover packaging, jobs and authored saves. | G7 stores the compiled game recipe as a Pipeline resource. T5 exports policy files; S6/G7 import them through Pipeline. Runtime game saves retain their own state semantics. |
| New assistant chat/model clients and provider lifecycle | [Agents workflow](../../../packages/zyren_agents/lib/workflow.dart), [HTTP models](../../../packages/zyren_agents/lib/io.dart), [provider plugins](../../../packages/zyren_agents/lib/plugins.dart) and [Studio extensions](../../../packages/zyren_studio/lib/agent_extensions.dart) already own those paths. | S2/S6/S7 reuse the current agent panel and registration/review lifecycle. A1 implements local tensor inference. A7 adds domain providers through existing transport. |
| Parallel editor docking and command/history shell | Studio already has selection, history, preview, persistence and agent panels. Dockable `StudioWorkspace` was being added during this audit. | S2 extracts and exposes contribution registration with the Studio owner. It preserves the current workspace, theme and panels. S3 adds only game authoring behavior. |
| A camera renderer/snapshot subsystem under AI | [Capture](../../../packages/zyren_capture/lib/zyren_capture.dart) uses [FrameSubmission](../../../packages/zyren/lib/src/rendering/frame_submission.dart) and native readback. | A6 adds persistent sensor capture in `zyren_capture`, plus missing generic renderer outputs. AI owns sensor configuration and tensor preprocessing. No separate frame snapshot pipeline. |
| Independent audio focus policy | [Capture Lab audio session](../../../packages/zyren_capture/example/flutter/lib/audio_session.dart) and its platform bridges already handle playback intent, foreground state and interruptions. Audio owns playback suspension, streams and spatial mixing. | G3 extracts/reuses the bridge with its owner. G6 adds semantic sound events for A3 hearing, which must still work when playback is muted. |
| A game collaboration protocol or profiler | Collaboration already owns authority/history/presence/offline operations. Devtools owns diagnostics, histories and external tooling. | S7 extends the existing protocol for component edits or marks them unavailable. G7/A7 contribute game/ML telemetry to existing tools. |

## Package inventory and ownership

This inventory covers every current top-level package. Reuse is conditional on
the feature a game enables; optional plugins do not become mandatory runtime
dependencies merely because they appear here.

| Package | Existing responsibility | Game/AI integration |
| --- | --- | --- |
| [zyren](../../../packages/zyren/README.md) | Scene graph, math, plugin services/scopes, input, controls and render contracts | Reuse throughout G1-G4/A6. Game systems govern simulation phases, not a second transform tree or resource scope. |
| [zyren_native](../../../packages/zyren_native/README.md) | Native rendering, backend worker, resource/ABI ownership and readback | G2 presents the existing scene. A6 extends only missing generic output capabilities. |
| [flutter_zyren](../../../packages/flutter_zyren/README.md) | Native scene widgets, declarative lifecycle, assets, shared empty states and onboarding | G3/S2 compose existing widgets. S6 registers real walkthroughs. |
| [zyren_gltf](../../../packages/zyren_gltf/README.md) | Imported scenes, models, materials and animation data | G4/G7 reuse import and independent model instances. No game-specific glTF loader. |
| [zyren_gltf_timeline](../../../packages/zyren_gltf_timeline/README.md) | Imported animation tracks and Timeline integration | G4/G6 reuse imported animation playback. |
| [zyren_physics](../../../packages/zyren_physics/README.md) | Rapier bodies, colliders, joints, queries, snapshots and stepping | G2 adds external driver ownership. G5 uses contacts/impulses for wheels. A3 consumes existing queries. |
| [zyren_characters](../../../packages/zyren_characters/README.md) | Motor, root motion, kinematic movement, rig/IK/retargeting and animation graph | G4 maps player/NPC intent to those controllers. No second motor or animator. |
| [zyren_navigation](../../../packages/zyren_navigation/README.md) | Baking, surfaces, obstacles, route following and Pipeline preparation | G4/A3 adapt destinations, updates and knowledge filtering. No second navigation mesh builder. |
| [zyren_interaction](../../../packages/zyren_interaction/README.md) | Scene routing, capture/focus, anchors and occlusion-aware picking | G3/G4/S6 reuse input ownership and tooling anchors; gameplay eligibility remains a game rule. |
| [flutter_zyren_interaction](../../../packages/flutter_zyren_interaction/README.md) | Flutter scene overlays, labels, widget surfaces and focus/input integration | G3/S6 reuse overlays and focus handling. |
| [zyren_tools](../../../packages/zyren_tools/README.md) | Selection, gizmos, editing tools and overlays | S2/S3 reuse tool services. Game creation tools register through the host. |
| [zyren_inspector](../../../packages/zyren_inspector/README.md) | Existing scene/property inspector UI | S2/S3 add game component editors through contribution registration. |
| [zyren_devtools](../../../packages/zyren_devtools/README.md) | Runtime diagnostics, counters/history and tooling | G7/A7 add game/ML measurements to current surfaces. |
| [zyren_agents](../../../packages/zyren_agents/README.md) | Scoped tools, registration/revision guards, external workflows and model clients | G7/S6/S7/A7 contribute domain tools. Native tensor policies remain A1/A2. |
| [zyren_studio](../../../packages/zyren_studio/README.md) | Versioned documents, prefabs, authoring/history, preview and persistence/agent hooks | S1 adds component extensions; S2 extracts UI contributions; G7 consumes expanded documents. |
| [zyren_pipeline](../../../packages/zyren_pipeline/README.md) | Bundles, pinned resources, incremental builds, transforms, caches and job lifecycle | G7/T5/S6/S7 use the existing container and host adapters. |
| [zyren_configurator](../../../packages/zyren_configurator/README.md) | Material/visibility choices, constraints, imported variants, viewpoints and hotspots | Optional cosmetic/loadout appearance and authored viewpoint adapter in G6. Item quantities and abilities are new game data. |
| [zyren_audio](../../../packages/zyren_audio/README.md) | Spatial/native playback, file streams, Doppler, occlusion gain and suspend/resume | G3/G6 bind host lifecycle and semantic game events. A3 adds hearing uncertainty and memory. |
| [zyren_capture](../../../packages/zyren_capture/README.md) | Native color PNG, turntable, tiled and video capture, capability reporting | A6 extends it with persistent sensor sessions. Keep the current job/export path. |
| [zyren_timeline](../../../packages/zyren_timeline/README.md) | Clips, layers/actions, markers, camera tracks and external clock | G4/G6 reuse animation/cutscene scheduling; game objectives and behavior trees remain separate. |
| [zyren_particles](../../../packages/zyren_particles/README.md) | Particle simulation, seeded fixed stepping, native rendering and effects | G6 emits events into the existing controller/plugin. |
| [zyren_effects](../../../packages/zyren_effects/README.md) | Native postprocess effects | Reuse for game presentation and declared camera sensor rendering. No separate effects engine. |
| [zyren_collaboration](../../../packages/zyren_collaboration/README.md) | Conditional operations, authority, offline queue, history and presence | S7 extends existing operations for component edits. It does not provide production game networking. |
| [zyren_engineering](../../../packages/zyren_engineering/README.md) | Review records, annotations and source identity | Preserve Studio review workflows. Optional game asset review; no role in NPC control. |
| [zyren_scientific](../../../packages/zyren_scientific/README.md) | Scalar/vector field and volume visualization | Optional field-backed game sensor adapter. It is not a gameplay physics solver. |
| [zyren_pointclouds](../../../packages/zyren_pointclouds/README.md) | Point cloud loading, streaming, rendering and queries | Optional level assets. A visual point sample does not establish a solid collider. |
| [zyren_splats](../../../packages/zyren_splats/README.md) | Gaussian splat rendering and appearance/query data | Optional visual environment. Require a declared separate collision/sensor policy. |
| [zyren_xr](../../../packages/zyren_xr/README.md) | Native XR sessions, tracking and physical environment inputs | Optional future host adapter. Physical depth input does not fulfill A6 virtual depth output. |
| [zyren_geospatial](../../../packages/zyren_geospatial/README.md) | Geographic coordinates, globe/terrain and atmosphere | Optional large-world coordinate/level adapter. Core game and ML remain geospatial-independent. |
| [zyren_3d_tiles](../../../packages/zyren_3d_tiles/README.md) | Tileset loading/streaming, providers and attribution | Optional streamed level assets. Preserve source identity and attribution through Pipeline. |

## Gaps confirmed by the source review

These are the new responsibilities, subject to rechecking the source before
each task starts:

- Game project/component contracts, entity generations and spawn recipes, action
  state, rule graphs, inventory/abilities/objectives, level lifetime and game saves.
- One game simulation driver for play and training. Physics already advances
  through an accumulator but currently also advances from `beforeRender`; an
  externally driven switch is required. The character motor accepts `Duration`,
  so the adapter must respect its precision and fixed-step tolerance.
- Wheeled vehicle dynamics and possession. No wheel/suspension vehicle controller
  was found in the reviewed package sources. Existing character movement stays
  in Characters and Physics.
- Studio document component extensions and public UI contribution registration.
  Prefabs, history, docking and assistant conversations already have owners.
- Local native model loading, tensor inference, batching and session lifetime.
  Agents' model interface handles text/tool requests rather than tensors.
- NPC observation schemas, bounded sensors, beliefs, goals, recurrent state,
  deadline handling and trained actions. Existing query APIs provide geometry,
  but do not define what an NPC knows or remembers.
- Persistent virtual camera sensing and depth readback. Current Capture jobs
  create isolated native captures and write PNGs. They are not persistent
  per-actor sensor sessions. Semantic class masks remain an optional extension.
- Training environment protocol, demonstrations, datasets, curricula, learning,
  held-out evaluation and native export parity. They consume the same simulation
  and Pipeline artifacts used by play.

## Checks required during implementation

Before adding a generic service, inspect its existing owner and current public
API under the shared-work rules. Extend that owner when the behavior is useful
outside games. Keep a game adapter where only game semantics are missing.
An existing README or a planned API is not enough to claim reuse is integrated.

The inspected regression sources include Studio authoring, Input/Interaction
arbitration and focus, Flutter overlays, Pipeline bundle/cache/build lifecycle,
Agents workflow/registration guards, and native character/physics paths. Q5 now
requires those affected suites alongside the new game tests. They were not run
as part of this documentation change.

Verify persisted Studio authoring, offline bundle loading, pointer ownership,
provider replacement during review, cancellation and repeated resource teardown
through the real adapters. Device rendering, gamepad/audio focus, camera latency
and trained behavior retain their own qualification gates. This audit removes
duplicate infrastructure from the plan; it does not mark those gates passed.

## Implementation recheck, 2026-10-03

The optional game/ML packages now use the owners listed above. Studio still owns authored prefabs/history and contributions; InputRouter retains pointer/focus arbitration; SceneView and the native backend retain presentation. Pipeline owns pinned assets, bundles and build jobs. Agents/Devtools own scoped external tools, Capture owns persistent sensor capture, and Rapier/Characters/Timeline retain physical and animation state. Native checkpoint motion and imported timeline identity extend those owners instead of replacing them.

The [release audit](release-audit.md) records source paths, checked adapters and remaining gates. The strict failure matrix passes all 25 named cases. Accepted structured models retain separate locked quality/parity evidence. Visual learned artifacts, full physical accessibility/target coverage and sustained capacity remain incomplete; repository authored data/model provenance does not provide a public redistribution license.
