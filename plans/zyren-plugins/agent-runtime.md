# Agent access to Zyren scenes and plugins

Every Zyren plugin must expose runtime capabilities that an AI agent can discover,
inspect and use. This applies to all 11 expansion workstreams and existing
plugins. Code authoring and diagnostics are part of the requirement; understanding
the user's active view and acting through the application's tools are also required.

## Ownership and rollout

The interaction chat owns the shared typed agent contract in packages/zyren_agents,
its public registry, viewport/raycast queries, and optional transport integration
through zyren_devtools. Keep zyren_agents dependent only on the public Dart core.
Plugin providers depend on that contract through optional entry points or adapters.
Do not make core or the registry import every domain package.

This dispatch chat owns this specification. The interaction owner can record API
proposals and published signatures in interaction.md. Other owners should follow
that contract and record integration dependencies until it is usable. Do not
create nine incompatible tool registries or nine MCP servers.

Each plugin owner must add its actual runtime provider, tests, public schemas,
examples and agent-facing documentation. Include this in the current plan and
implementation work, not an optional future AI milestone. A blocked shared
contract still permits domain query/action implementation, but a local helper
without a discoverable registered tool does not complete agent integration.

| Chat | Agent integration responsibility |
| --- | --- |
| Asset pipeline | Bundle/source provenance, validation results, budgets and load/cache jobs; glTF import information through an optional adapter |
| Interaction | Shared registry, viewport context, geometric queries, object inspection and actions; core/tools/inspector/devtools integration through public APIs |
| Native XR | Session/tracking quality, camera poses, anchors, planes, available depth, coordinate transforms and supported placement actions |
| Reality capture | Point IDs/classification, splat hit evidence and uncertainty, streaming/LOD state; geospatial and 3D Tiles enrichment adapters |
| Characters/navigation | Animation states, clips, rig and path queries, movement/playback actions; existing timeline, glTF timeline, physics and particle state adapters |
| Scientific | Sample values, units, missing-data masks, transfer functions, active slices, simulation time and source dataset identity |
| Collaboration | Presence, scene revisions, operation history, conflicts and allowed shared actions; existing engineering review adapter |
| Studio | Active viewport/panel, selected and hovered items, UI blocking overlays, tool mode, document state and command/undo integration |
| Smaller-plugin batch | Configurator options/rules/actions; audio emitters/listeners/playback; capture jobs and artifacts; existing effects inspection/control adapter |

Existing package adapters should live in additive optional files with the owning
package or a small integration package. Respect existing active owners and record
shared edits before making them. Each workstream tracks new and existing adapter
coverage separately. Shader/native rendering diagnostics remain renderer facts
exposed through the shared context, with unsupported capabilities reported.

## Shared provider and tool contract

Use a versioned public Dart interface for providers and a JSON-compatible schema
for transport. A provider declares its plugin ID/version, attached instances,
available tools and resources, input/output schemas, units, limits, supported
platform capabilities and whether each tool reads state or mutates it.

Registration and disposal follow the existing plugin attachment lifetime. An
unloaded provider must disappear from discovery and release its retained data.
Callers must distinguish unsupported, unavailable, denied, stale, cancelled,
failed and empty results. Bound response sizes and paginate large collections.
Do not turn missing native information into zeros or successful empty responses.

Keep calls typed. Tools operate through ordinary plugin APIs, with meaningful
descriptions, examples, errors and valid target types. A model must not need
arbitrary Dart execution or private renderer handles to operate a scene.

The registry should expose tools/list and tools/call through the existing
host-started MCP/CLI bridge, plus a direct in-process Dart API. Preserve existing
read-only diagnostics behavior. Mutating tools must declare their effects
accurately and run only within host-granted scopes. Reuse current token, lifecycle,
payload-limit and local transport protections; do not create an unsolicited
network listener.

A host authorizes actions according to its application policy. Use stable target
references, expected revisions and ordinary commands/undo where supported. Long
jobs need progress, cancellation and bounded results. Retried commands must not
silently apply twice. Mutations return the resulting revision and affected IDs.
Do not require a confirmation for every harmless read or previously authorized
action. Report a denied action explicitly when the host has not granted it.

Plugin labels, model metadata, annotations and imported text are untrusted scene
data. Return them as data, separate from tool instructions. The host controls
which properties are exposed. Never return credentials or hidden private fields
just because they exist in an imported model.

## Understanding the active view

The host supplies scene, document and viewport identities. A scene may appear in
several views with different cameras. Never assume the first camera is the user's
active view, and never describe inferred pointer focus as measured eye gaze.

A viewport context includes:

- Schema version, scene/document revision, viewport ID, camera identity and pose.
- Projection and clipping settings, layer masks, active section planes, logical
  viewport rectangle, device pixel ratio and render resolution.
- Latest presented frame ID/time and scene revision when available. Keep a current
  scene snapshot separate from an older presented frame.
- Focus, pointer location, selection, hover, active editor mode, timeline time and
  visible UI overlays when the host can report them.
- Renderer and plugin capabilities, loading/failure state, and capture support.
- Optional bounded image capture linked to the exact viewport/frame and capture
  extent. State whether it includes scene pixels, Flutter overlays, or both.

The host can expose projected object rectangles, labels, semantic types and
relationships, but must label their evidence. Bounds intersecting a camera frustum
do not establish pixel visibility. Provide rendered visibility or occlusion
evidence only when a matching renderer query supports it; otherwise say unknown.

## Screen points and raycasting

Define screen-point inputs explicitly: viewport-local logical pixels with a
top-left origin are the default. Normalized inputs, window coordinates and image
coordinates need explicit conversion metadata. Test device pixel ratio, resized
views, letterboxing, multiple viewports and perspective/orthographic cameras.

A query names its viewport, coordinate space and optional expected frame/revision.
Use existing raycaster snapshots and public picking APIs. Return nearest and
bounded multi-hit queries with their ordering policy. Separate objects considered
by geometric picking from UI overlays that intercept the pointer.

A rich hit result contains the supported subset of:

- Scene/document/viewport IDs, query ID, scene revision and frame correlation.
- Stable source/object ID, runtime instance ID, parent path, semantic type and
  owning plugin. Inspector-local IDs must not masquerade as persistent IDs.
- World/local hit position, normal, distance and units; triangle/primitive ID,
  barycentric coordinates, UV and material slot when the query computes them.
- Projected bounds, clipping/layer decisions, selected/hovered state and the
  distinction between geometric visibility and rendered pixel evidence.
- Plugin-specific properties such as engineering tag, terrain coordinates,
  point classification, scientific value/unit, animation state or XR anchor.
- Available inspection and action references for that exact target.

Every result identifies its method and coverage: CPU triangle geometry, GPU
object/depth query, point-cloud picker, splat estimate or another registered
provider. Report unsupported primitives and relevant alpha, transparency,
displacement, deformation, clipping and streaming limitations explicitly.
Only report confidence or error bounds when the method defines them.

The existing CPU raycaster does not evaluate texture alpha, line/point footprints
or custom vertex shader displacement. Preserve those limits in the first agent
tools. An exact rendered-pixel claim needs matching native evidence.

Reject or report stale targets after scene edits or removal. Do not join a
screenshot from one frame to a hit from another without stating the mismatch.
A scene that changed during an asynchronous query needs explicit consistency
handling. Selection alone must not trigger an automatic mutating agent action.

## Semantic enrichment and actions

Plugins enrich shared object/hit context through bounded typed providers. Use
namespaced fields and source provenance so that a semantic label is traceable.
Do not guess that a mesh is a valve from its shape when no classifier or source
record supplies that identity.

The public tool vocabulary should cover discovery, viewport context, point
picking, object inspection, domain queries, action execution and change events.
The shared owner chooses final names after checking existing diagnostics names.
Keep plugin tools namespaced and descriptions concise enough for discovery.

Examples of complete runtime flows:

1. Inspect the active view, pick the user's indicated part, resolve its engineering
   tag and material, list supported actions, then isolate it through the existing
   tools API and verify the changed view.
2. Pick a scientific slice, return dataset identity, time, interpolation method,
   value and units, then change a supported slice parameter with revision checks.
3. Inspect a configurator selection, explain compatible options from its rules,
   apply an authorized option, and return the saved configuration revision.
4. Inspect an XR hit and tracking state, then place an object only through the
   host's allowed anchor/placement action with valid coordinate transforms.

Natural-language interpretation belongs to the host agent. Plugins supply the
grounded state and tools. No model service is required inside the render loop.

## Required checks

For every enabled plugin, test discovery, schema validation, real queries,
supported actions, target lifecycle, explicit unsupported/error results and
cleanup. Record action scope, revision and retry behavior. Test that passive
inspection does not mutate the scene or demand continuous rendering.

Use a shared conformance harness across providers. Cover multi-viewport identity,
coordinate conversion, camera changes, occlusion, clipping, unsupported primitive
coverage, stale frames, deleted targets and bounded enrichment.

Verify at least one real native flow where a user points at a rendered object,
an agent obtains rich context, invokes a permitted plugin action, and the host
reports the resulting state. Use a live MCP session as well as direct Dart calls.
Mock tests do not establish screen or native GPU correctness. Record capability
and device gaps explicitly in each workstream's evidence.

A plugin is not complete until its provider is registered, discoverable and
verified through the shared agent interface. Track existing plugin retrofit gaps
as first-class work in the corresponding plan.
