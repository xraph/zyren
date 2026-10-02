# Characters and navigation

You can use this workstream to drive imported animation states and query a small
authored navigation mesh. The first checkpoint covers explicit state changes and
point-agent routes. Root motion and a collision-aware character controller need
separate milestones.

## Source audit and decisions

The audit on 2026-10-02 found these public APIs already implemented:

- `zyren_gltf` loads glTF animations and supplies instance-owned sampled poses.
  `ModelInstance.prepareBlendedPose` applies joints, morphs and deformation.
- `zyren_gltf_timeline` supplies `modelClip`, `modelRestClip` and
  `ModelAnimationTrack`. These preserve the imported instance hierarchy.
- `zyren_timeline` supplies independent `TimelineAction` clocks, interrupted
  fades, target validation and frame demand. Its plugin runs in dependency order.
- `zyren_physics` supplies native Rapier worlds, capsule colliders, shape queries,
  kinematic targets and fixed-step scene synchronization. `PhysicsPlugin` rejects
  competing transform writes and changing parent transforms.

Keep both new packages in Dart. Navigation depends only on `zyren`; characters
depends on the core and existing glTF/timeline adapters. Physics stays an optional
example dependency. We do not need a core or native ABI change for this checkpoint.

### Transform, units and update order

1. Use metres, seconds, radians and Y-up coordinates. The initial mesh is a flat
   XZ surface at one elevation, with indexed triangles and shared vertex IDs.
   Queries reject points off the surface. They do not silently project a floor.
2. Physics owns a unit-scale outer character group. Put the imported instance
   beneath it. Timeline tracks own only the imported instance's local pose.
   Do not bind imported joints or the instance itself to physics.
3. The first example uses explicit fixed ticks: query/sample the route, submit
   a kinematic body target, advance `PhysicsPlugin` by one world step, then render
   with an explicit timeline delta. Only one driver steps the physics world.
4. A character plugin depends on the timeline. After the timeline samples a frame,
   it pauses actions whose fade reached zero, so hidden looping states release
   frame demand. Detach disposes the actions before the timeline detaches.
5. State requests follow an explicit directed transition graph. An interrupted
   fade starts from current weights; it fades every other state to zero. The
   destination resumes its own clock. Locomotion policy belongs to the host.

Navigation returns a deterministic triangle corridor and portal-midpoint route.
Every segment stays in a corridor triangle. This route is not a shortest-path
funnel result and has no agent-radius clearance guarantee. Mesh construction
rejects degenerate, overlapping and non-manifold triangles and T-junctions.
Bounds keep validation and queries suitable for small authored meshes.

## Phases and acceptance

| Phase | Work | Acceptance and dependency |
| --- | --- | --- |
| 1 | Named animation states, directed transitions and imported clip adapters | Real glTF load and timeline sampling tests cover fades, interruption, invalid edges, removal, disposal and frame demand. Reuse existing timeline APIs. |
| 1 | Validated flat navmesh, bounded path query and distance sampling | Known connected/disconnected fixtures, outside points, invalid topology, deterministic routes and segment containment pass. No renderer dependency. |
| 1 | Character route example with native Rapier | An imported animated character follows a route using a kinematic capsule and physics-owned outer transform. Assert target arrival and cleanup. CPU scene tests and native physics checks are separate from GPU presentation. |
| 2 | Root motion | Extract local root displacement including loop crossings, convert to world intent once per fixed step, consume collision-resolved motion and remove visual root displacement. Require timeline sampling/commit separation before sharing the clock with physics. |
| 2 | Character collision | Sweep capsule, slide, floor snap, slope limit, step height, moving platforms and grounding. Use Rapier queries and versioned controller settings; verify corners, stairs, thin walls, slopes and large frame deltas. |
| 3 | Dynamic obstacles | Version navigation data, invalidate stale paths, replan under a bounded budget and stop when no safe path exists. Test obstacle insertion/removal, cancellation and agent clearance. Physics supplies actual collision constraints. |
| 3 | Navmesh generation | Bake walkable triangles from scene geometry with agent radius, height, slope and step settings; preserve source IDs and transform revisions. Validate seams, islands, holes and multi-floor queries. Pipeline integration waits for its public asset contract. |
| 4 | Retargeting | Explicit rig mapping, bind-pose validation, units and joint-axis correction. Preserve source joint IDs; compare reference poses and foot contact across different proportions. |
| 4 | IK | Apply bounded two-bone and look-at solvers after animation blending, before deformation. Foot placement consumes resolved ground contacts. Requires a shared prepared-pose extension, joint limits and unreachable-target tests. |
| 5 | Native walkthrough qualification | Render representative skinned characters on available Metal/Vulkan/DX12 devices; verify route arrival, transitions, pause/resume, removal and resource cleanup. A later interactive example needs desktop/narrow layout checks. |

## Shared-file requests

- `pubspec.yaml`: append `packages/zyren_characters` and
  `packages/zyren_navigation` under the shared directory lock. Preserve entries
  added by other chats. Dependency resolution may update the workspace lockfile.
- `tool/check_package_boundaries.dart`: add the two packages' public import
  allowlists under the lock after checking other plans for overlap. No core
  dependency gains a domain plugin.
- Later fixed-step root motion needs a pre-step callback or prepared-pose clock
  contract across timeline and physics. This checkpoint does not edit either API.

## Runtime agent access

Agent access is required for completion. Use the versioned `zyren_agents`
contract owned by the interaction chat, with optional adapters and its existing
devtools transport. At the time of the requirement update, that package had not
been created. Typed domain queries and actions can proceed while it is prepared.

Expose state IDs, clip duration/targets, weights, playback positions, rig node
indices and allowed outgoing edges. Navigation tools return query status,
triangle corridor, bounded waypoints, metres and the flat point-agent coverage
limit. Playback mutations use normal state/transition/pause/resume APIs. Movement
must target a host-owned controller; the first route query grants no right to
write a physics-bound transform.

This chat also owns optional existing-plugin adapters for timeline and glTF
timeline, physics, and particles. The adapters must preserve their clocks,
simulation owners and disposal rules. Include playback/seek, physics inspection
and host-command movement, and particle state/control where the public API
supports it. Record unsupported actions explicitly.

Provider acceptance includes discovery and schema conformance, passive reads
without frame demand, scopes, expected revisions, command retry behavior,
removed targets and registry cleanup. The shared viewport supplies document,
scene, camera and frame correlation. Rig and navigation data enrich geometry
hits without claiming exact rendered pixels. Native screen-to-action and live
MCP checks remain separate from direct Dart checks.

Owned paths are this plan, `packages/zyren_characters/**` and
`packages/zyren_navigation/**`. The example lives inside the character package.

## Checkpoint evidence

Implemented checkpoint 1: named states and transitions over real glTF/timeline
clips, interrupted fades, pause/resume and zero-weight action cleanup; validated
flat triangle meshes, bounded queries and route distance sampling; a package-local
native renderer example with an imported rigid-limb robot and Rapier capsule.

Verification on 2026-10-02 uses Flutter 3.47.5's Dart:

- `dart analyze packages/zyren_characters packages/zyren_navigation`: clean.
- Character package `dart test --concurrency=1`: 6 tests pass, including native
  Rapier arrival within `1e-5` metres and resource counts restored after cleanup.
- Navigation package `dart test --concurrency=1`: 6 tests pass. The L-floor route
  length is `2.848528137423857` metres (tolerance `1e-9`); 1001 sampled positions
  remain on the mesh. This tests containment, not shortest-path optimality.
- Package boundary guard, Apple ABI header guard and `git diff --check`: pass.
- Running the native physics test from the workspace root omitted its hook.
  Running from the character package resolves the real native asset and passes.

Checkpoint 1 is committed as `892ccf1`. The agent checkpoint below extends it.
Phases 2 through 5 remain.
An existing `physics_lab` macOS process
was active during reconnaissance, so this chat will not take its device session.
Native Rapier CPU checks do not establish Metal presentation. Packages remain
private with `publish_to: none`. No publication is requested.

### Existing-plugin agent adapter edits

Checkpoint 1 is committed as `892ccf1`. The shared provider contract is now
available, so the next checkpoint implements optional `agents.dart` entry points
for characters, navigation, timeline, glTF timeline, physics and particles.

Shared edits requested: append `zyren_agents` to each adapter package's pubspec
and allowlist; create only `lib/agents.dart` in the four existing packages.
Current status shows no other edits in those packages. Preserve the existing
facades and runtime implementations. Use the lock for these additive edits.

Hosts supply revision readers and command gateways. A gateway records the normal
application command/undo policy, checks cancellation immediately before applying,
and increments the host revision. Frame/external edits must update that revision
as well. Providers register into an attachment scope and never start a listener.
Physics movement only submits targets to explicitly exposed kinematic bodies;
it does not step the world. Particle queries use cached measurements and do not
force GPU readback. Native particle actions still need a live attached controller.

## Agent checkpoint evidence

Implemented optional providers in `agents.dart` for characters, navigation,
timeline, imported glTF animation, physics and particles. The walkthrough mounts
five domain providers plus viewport context in one attachment lifetime. A second
character plugin now rejects an already-owned animation target.

Checks on 2026-10-02:

- Character package: 13 tests pass; one native particle GPU test is skipped.
- Navigation package: 7 tests pass, including shared-registry path queries.
- Analyzer: clean for both packages and all four existing-plugin adapter files.
- Live stdio MCP subprocess: passes initialization, tools/list, six-provider
  discovery, enriched character geometry picking, authorized state transition,
  retry deduplication, rejection of mutation through the query channel, and
  existing diagnostics. The fixture uses native Rapier and a test renderer.
- Registry conformance covers passive reads, schemas, permission denial, stale
  revisions, missing fields, cancellation, removed bodies/models and scope cleanup.
- Native physics arrival and cleanup remain verified. The particle adapter's
  schemas are verified; its real GPU state/action test has not run.
- The repository-wide boundary guard initially reported the shared devtools
  agent imports missing from its allowlist. The final shared-file request adds
  only `zyren_agents` to that transport allowlist; it changes no runtime code.
- One dependency-resolution attempt encountered an XR example before its owner
  had registered it. Resolution passed after that registration completed.
- Disk exhaustion interrupted temporary adapter preparation. Only this
  workstream's disposable test caches were removed; source files were preserved.

No screen presentation, Metal/Vulkan/DX12 character render or native particle
agent action is claimed. The active native sessions were left alone. The MCP
geometry result correctly reports rendered pixel visibility and presented-frame
correlation as unknown. Live screen-to-action qualification is still required.

Remaining work: root-motion extraction, a collision-aware character controller,
dynamic obstacles, generation and multi-floor navigation, IK, retargeting,
representative skinned rigs, and native desktop/mobile walkthrough qualification.
The agent providers need the same native qualification before plugin completion.
The example's command gateway has no undo stack; product hosts must supply their
normal command history, permission policy and revision updates. Packages remain
private. No push, merge or publication was performed.


### Final shared-file request

Add `zyren_agents` to the `zyren_devtools` allowlist in
`tool/check_package_boundaries.dart` so the existing transport exercised by the
MCP test has the same dependency rule as its pubspec. Preserve all concurrent
entries and serialize the edit and commit under the shared lock.

### Commits and final state

- `892ccf1`: animation states, validated navigation and native Rapier walkthrough.
- `b20dbe7`: six domain agent adapters, shared viewport enrichment, registry and
  live stdio MCP checks, and duplicate character-owner rejection.
- Automated behavior: 13 character tests and 7 navigation tests pass. One native
  particle GPU test is skipped. Analysis is clean.
- Live evidence: native Rapier CPU behavior and actual MCP stdio passed. Character
  presentation and particle GPU actions remain unverified on native devices.
- Backlog and host requirements remain as listed above. These are useful
  implementation checkpoints, not complete or published plugins.
