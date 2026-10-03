# Rendering performance and smooth globe navigation

You should be able to move through a streamed world without stippled tile
transitions, incomplete replacement coverage or a frame upload failure. We will
implement the six rendering improvements from the approved chat proposal, then
improve physical materials, transmission and indirect lighting.

## Spec and constraints

The user approved all six recommendations and the PBR improvements on October 3,
2026. The concrete complaint is grain during camera motion before tiles settle.
The chat request is the specification. This document records implementation and
verification boundaries, not completed results.

- Keep Metal, Vulkan and DX12. No browser or OpenGL renderer.
- Work on the current main branch, preserving concurrent scientific and manifest
  edits. Stage exact owned paths. Commit coherent tested changes; no push or merge.
- Never use agent attribution in branches, commits or prose. Apply rex-voice and
  humanizer in embedded mode to shipped prose. No em dashes.
- Use Flutter/Dart 3.47.5 through FVM. Native tests must exercise real shaders.
- Keep scopes, generation checks, cancellation, resource retirement and device
  loss recovery correct. Missing GPU metrics remain null.
- Keep generic rendering in core. Ellipsoid policies belong in optional packages.
- Parent coverage stays until a complete replacement is ready. Prefetch work has
  a separate bounded allowance and cannot displace visible coverage.
- Preserve transparent ordering, explicit render order and material semantics.
- Do not equate tests or small readback fixtures with foreground device FPS.

## Task 1: Frame profiling

Own native timing/diagnostics, their Dart decoding and the navigation collector.
Extend existing frame timing to named rendering passes and resource-graph GPU work,
CPU preparation and GPU completion waits. Avoid introducing synchronous waits for
telemetry. Define what overlaps and what is excluded. Unsupported pass timing stays
null. Report submission count, draw preparation allocations/cache reuse and upload
pressure using actual counters where those facilities exist; later tasks can add
their counters through the same contract.

Tests must cover supported/unsupported timing, bounded query lifetime, failed-frame
handling and native-to-Dart schema compatibility. Update the collector to retain
the fields and compare complete phases. Run focused tests then affected package
checks. Record commands, source and limitations in task-1-report.md.

## Task 2: GPU scheduling and bounded uploads

Own resource runtime submission/retirement, scene packet upload admission and
backend integration. Batch dependent graph work without a CPU completion wait
between each graph and main scene. Preserve ordered uniform writes and retained
resources until the corresponding submission completes. Introduce bounded in-flight
work only where native presentation ownership can be proved. Use explicit fences
at readback, external handoff and shutdown; preserve timeout/device-loss behavior.

Fix the recorded scene upload budget failure without raising limits. Stage large
resource uploads in bounded chunks and publish scene changes only when all needed
resources are ready. Continue presenting the previous complete cover while staging.
Expose upload backlog and staged bytes through Task 1 diagnostics. Cancellation,
failed preparation and retries must not accept incomplete encoder revisions.

Test large turns, repeated replacements, single oversized assets, byte/vertex/index
limits, cancellation, multiple views, resource closure and GPU timeout. Run real
native graph/scene tests and transport tests. Report verification and any presenter
constraint explicitly.

## Task 3: Retained draw preparation

Own renderer uniform and binding preparation. Replace per-mesh transient uniform
buffers and bind groups with bounded reusable per-view resources. Write dirty
ranges and retain bindings until their resource keys or layout change. Keep frame
slots independent when more than one submission is allowed. Expose allocation,
write and reuse counters. Retire correctly on resize, close and failed submission.

Test warm stationary frames, camera-only changes, material edits, visibility churn,
transmission capture, multiple views, resizing and complete cleanup. Compare a
many-mesh fixture at equal content and resolution; report CPU timing separately.

## Task 4: Globe selection, prefetch and tile transitions

Own zyren_3d_tiles and Planet integration. Add optional conservative ellipsoid
horizon culling through a policy/callback that keeps the generic tile package free
of mandatory geospatial dependencies. Integrate the Earth policy in Planet.
Add bounded camera-motion prediction and adjacent-view prefetch with visible work
first, cancellation, freshness and cache accounting. Relax SSE smoothly while
moving and recover detail when settled without refinement oscillation.

Remove random stipple as Planet's default LOD transition. Retain a full old cover
until a complete child set is ready, admit replacement uploads through Task 2, and
use a visually stable transition that respects opaque depth and blended assets.
Do not hide grain by blurring the entire scene. Keep attribution and feature picks
correct during replacement. Preserve existing explicit fade APIs compatibly.

Tests cover offscreen/predicted requests, camera reversal, large turns, bounded
prefetch, incomplete siblings, failed children, horizon/height edge cases, current
viewport pixel SSE, error/retry, stable coverage and native transition images.
Wire the policy into the live Planet consumer and its diagnostics.

## Task 5: Adaptive clouds and shadows

Own geospatial cloud temporal reconstruction and adaptive quality. Reproduce grain
on camera motion independently of tile fade. Improve invalid-history spatial
reconstruction and disocclusion handling, retaining true camera-cut rejection.
Use measured GPU cost to choose bounded cloud ray resolution and shadow cadence
with hysteresis. Reproject valid history and stable shadow cascades when skipped.
Keep animated wind and lighting changes correct. Avoid reallocating all targets
on small budget changes; make overrides and unavailable timing behavior explicit.
Investigate conservative occupancy skipping beyond the existing weather skip;
implement it only with source-density bounds and shader evidence.

Tests cover pan/orbit/zoom, newly exposed pixels, camera cuts, resize, lighting,
animated weather, unsupported timing, cadence and convergence. Native image checks
must distinguish smooth fallback from temporal ghosting. Preserve pinned source
preset semantics when adaptive quality is disabled.

## Task 6: Opaque ordering and batching

Own renderer draw ordering and compatible draw batching. Within explicit render
order, group opaque draws by pipeline/material and coarse depth to reduce state
changes and overdraw. Preserve transparent global ordering, mask, sides, mirrored
transforms, selection outlines and transmission passes. Reuse existing instancing
for truly compatible repetitions, with stable picking identity.

Tests cover material switches, near/far draw ordering, explicit overrides,
transparent instances, mirrored geometry, outlined objects and draw counters.
Measure many-mesh scenes without changing image content.

## Task 7: Physical material accuracy and shader cost

Own PBR shader variants, BRDF integration and material quality controls. Specialize
inactive physical lobes, hoist view-dependent terms out of punctual light loops,
and bound variant growth. Add consistent multiscattering energy compensation to
direct and environment lighting, with correctly generated LUT data. Add specular
anti-aliasing and roughness/view-dependent specular occlusion. Preserve linear/sRGB
map semantics, glTF factors, tangent handedness and optional material layers.

Tests include white-furnace/rough-metal energy, analytic or independently integrated
BRDF samples, normal-map motion, disabled-layer equivalence, layered energy bounds,
glTF import and native material fixtures. Add public examples and documentation.

## Task 8: Transmission and indirect lighting

Own transmission capture/filtering, local reflection probes and optional screen
effects. Reuse opaque scene results where compatible; provide bounded filtered
rough transmission and a cheaper smooth-glass path while preserving depth rejection,
dispersion, alpha and multisampling. Add local probes with amortized updates through
public graph/environment APIs. Add optional screen-space reflections and ambient
occlusion with explicit quality/memory budgets, temporal validity and offscreen
fallback. Keep atmosphere environment updates compatible.

Test foreground rejection, offscreen rays, smooth/rough glass, dispersion, resize,
depth conventions, multiple views, probe updates, history cuts and scope cleanup.
Exercise the features in the native shader lab, with controls and documented costs.

## Task 9: Integrated qualification and documentation

Run affected Dart/native suites, static analysis and native shader fixtures. Run a
foreground Planet route with real tiles if the configured provider and unlocked
devices permit it. Compare stationary, orbit, drag, zoom and reversal at matched
resolution/content. Record presentation P50/P95/P99, named timings, uploads, backlog,
tile coverage, histories, memory and cleanup. Inspect desktop and narrow layouts
when controls change. Restore the normal interactive app after testing.

Update capability/parity documents from actual code and evidence. List missing
device or provider qualification separately. Complete a fresh review of the full
change and address correctness findings before declaring completion.

## Review focus

Audit GPU resource lifetime across queued work, per-view isolation, temporal
history publication, bounded staging under cancellation, complete tile coverage,
prefetch priority inversion, camera reversals, ellipsoid bounds, transparency and
material energy. Confirm no performance claim uses diagnostic sampling frequency
or an inactive application as presentation FPS.
