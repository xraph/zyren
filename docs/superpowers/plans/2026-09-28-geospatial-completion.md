# Geospatial completion implementation plan

> Execute this program with `superpowers:executing-plans`. Keep the full request
> active through all five workstreams, with tests and focused local commits.

**Goal:** Implement the five remaining geospatial workstreams requested on
September 28: provider tiles, terrain/imagery, atmosphere, clouds/effects and
qualification. The broader animation/skinning engine backlog is separate.

**Architecture:** Extend optional Dart packages over the existing asset scopes,
scene plugins and public native shader/render graph APIs. Keep native Metal,
Vulkan and Direct3D 12 rendering. The core must not import geospatial.

**Tech stack:** Flutter 3.47.5, Dart SDK >=3.10.0, Rust 1.97.1, wgpu 30.0.1.

**Spec:** The user's five-item request, `docs/parity/matrix.md`, the pinned source
inventory and `docs/design/native-3d-api.md`. The supplied three-geospatial tree
is the source reference. External tile formats follow CesiumGS 3D Tiles.

## Global constraints

Work in the primary checkout on main as requested. Preserve concurrent work.
Commit checked changes locally; do not push, merge or publish. Keep credentials
in caller-owned configuration, outside the rendering core and logs. Provider
access and actual platform availability are verification gates, not assumptions.
Use rex-voice and humanizer for shipped prose; no em dashes or co-author trailers.

## Workstreams and acceptance

| Workstream | Deliverables | Acceptance |
| --- | --- | --- |
| 1. Real-world tiles | External and implicit hierarchies, provider auth/refresh and attribution, compressed content, feature styling and fades | Valid and malformed format fixtures, bounded request/cache lifetimes, actual native provider or public data rendering, cancellation/retry/disposal |
| 2. Terrain/imagery | Provider imagery, dynamic terrain availability, overlays, Manhattan/Fuji configurations | Real transport/decode, UV and geographic placement fixtures, live update/error/retry checks and native scenes |
| 3. Atmosphere | Source LUT loaders, automatic material lights, environment/probe adapters, spectral integration and remaining haze variants | Pinned numerical references, native rendered comparisons, parameter changes and scoped cleanup |
| 4. Clouds/effects | Volumetric layers/weather, cloud shadows, temporal reconstruction, lens flare, grading/blur effects | Source defaults and deterministic generators, native pixel checks, moving cameras/weather, camera cuts and resize/history retirement |
| 5. Qualification | All 74 story cases, new-loader mobile checks, Windows/Linux host checks and representative benchmarks | Per-story and per-platform recorded results; unavailable credentials/hardware remain explicit blockers |

## Task 1: External tilesets

Files: `packages/zyren_3d_tiles/lib/src/{tileset,content,streamer}.dart`, new
`external_content.dart` and `test/external_test.dart`, native fixture and docs.

Consume `AssetDecodeContext`, `TileNode3D`, `Tileset3D` and the existing physical
request tracker. Produce lazily fetched external hierarchies in the same
scheduler, with ordinary `TileModel3D` groups for renderable payloads. Prefix
child identities with the referring node, compose its transform, resolve URIs
against the effective external URL and retain the document ancestry for cycles.

- [x] Write regressions using a memory resolver: transformed root -> external
  JSON -> GLB, extensionless JSON, redirect cycle, failure/retry and cancellation.
  Assert world translation, parent fallback and that cycles issue no unbounded
  reads. Run `dart test test/external_test.dart`. Expected: unsupportedFeature.
- [x] Separate streamed hierarchy/model payloads without changing the public
  `Tiles3D.content` model API. Parse nested roots with inherited refinement and
  a shared depth ceiling. Count cached manifest nodes in decoded payload bytes.
- [x] Recompute selection after a hierarchy arrives. External links contribute
  no visible group; their descendants determine coverage. Keep their scopes and
  physical request slots under the same lifetime rules as model content.
- [x] Run `dart analyze` and `dart test --concurrency=1` in the tile package.
  Expected: all pass. Add an HTTP native nested fixture, run it, then commit.

## Task 2: Implicit tile subtrees

Files: tile parser and streamer, new `implicit.dart`, `subtree.dart` and
`test/implicit_test.dart` in `packages/zyren_3d_tiles`.

Represent each subtree boundary as a non-renderable resource node. Decode its
availability into bounded ordinary tile nodes and deferred child-subtree nodes.
Share the streamer's existing request slots, scopes, fallback and cache. Content
and subtree templates resolve from the original effective tileset URI; binary
buffer references resolve from the effective subtree URI. Compute box/region
bounds from the original root and integer global coordinates to avoid drift.

- [x] Add failing fixtures for quad/octree constants, sparse Morton bitstreams,
  JSON and binary subtrees, external availability buffers and lazy boundaries.
- [x] Add configured subtree-node limits. Validate depth, bit lengths, trailing
  bits, parent/content consistency, buffer alignment/ranges and URI policy before
  publishing nodes. Reject unsupported metadata overrides explicitly.
- [x] Test inherited transforms, dateline regions, available-level termination,
  malformed binary lengths, cancellation and parent coverage on failed subtrees.
- [x] Run analyzer, package suite and a native fixture before a focused commit.

## Task 3: Provider transport, sessions and attribution

Files: core asset transport value types, native resolver, glTF asset metadata,
new tile provider adapter and provider lab in Planet, with transport/provider
and visible-attribution tests.

Use caller-owned secrets to open Google Maps directly or resolve a Cesium Ion
endpoint. The existing TwinOS Ion token can access Google's asset 2275207. Keep
that token at the Ion endpoint and the issued Google key at the Google origin.
Return sanitized effective URIs and typed errors. Refresh expired sessions once,
coalesce concurrent refreshes, and retain physical cancellation ownership.

- [ ] Extend SourceReadContext with immutable request headers, ResolvedSource
  with immutable response cache headers, and AssetLoadException with optional
  HTTP status. Native redirects drop credentials across origins. Test bounds,
  cancellation, auth status and redirects before implementing.
- [ ] Implement bounded provider endpoint/session reads over ByteSourceResolver.
  Test Google keys/sessions, Ion external and bearer endpoints, concurrent refresh,
  denial, secret-free diagnostics and cancellation. Keep endpoint validation
  narrower than caller URI policy so a permissive policy cannot leak credentials.
- [ ] Retain glTF copyright metadata and aggregate attribution from visible tiles.
  Carry provider credits and render readable Google Maps/data-source attribution.
- [ ] Honor response freshness and keep provider content in memory for the active
  visualization. Add a native Manhattan lab, load the authorized Google dataset,
  and record transport versus rendered results separately. Compression failures
  advance Task 4 before claiming the live provider rendering gate has passed.

## Subsequent task order

2. Implicit quadtree/octree coordinates, subtree availability parsing and lazy traversal.
3. Provider requests, token refresh, attribution and public dataset lab.
4. Compressed geometry/textures through optional decoder integrations.
5. Feature styling and refinement fades with bounded transition resources.
6. Imagery sources and UV composition over terrain.
7. Dynamic terrain availability and water/vector overlays.
8. Manhattan/Fuji scene configurations with caller-provided provider access.
9. Source atmosphere LUT transport and binary/EXR decoding.
10. Automatic sun/sky lighting and environment/probe adapters.
11. Spectral integration and remaining haze/overlay variants.
12. Cloud parameter/default parity and deterministic weather/shape/detail generators.
13. Native volumetric cloud integration and shadow passes.
14. Temporal cloud reconstruction and camera/weather history invalidation.
15. Lens flare, source grading and blur effects.
16. Native story harness, pinned inputs and all 74 comparison records.
17. Pixel/iPhone loader and combined-scene qualification.
18. Windows/Linux GPU qualification and representative performance measurements.

Before each subsequent task, write its concrete interfaces and failing fixtures
in this plan using the established APIs and source reference, then implement it.
Do not mark a workstream complete because only its first task has landed.

## Review focus

- Nested or cyclic hierarchy URLs, redirect aliases and changing credentials must
  not escape the host URI policy or leak secrets in failures.
- Implicit availability, terrain metadata and compressed counts must be bounded
  before allocation, including arithmetic overflow and hostile nesting.
- Parent fallback, fade transitions and source replacement must preserve coverage
  while enforcing logical CPU/GPU budgets and retiring actual asynchronous work.
- Atmosphere/cloud history must survive ordinary camera movement and reset on
  cuts, resize or incompatible weather changes without ghosted stale frames.
- Qualification must distinguish fixture, live provider, simulator and physical
  device evidence. Unavailable targets cannot receive a passing status.
