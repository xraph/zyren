# Asset pipeline

You can build this workstream in `packages/zyren_pipeline`. Its example stays
inside that package. Shared core and native renderer files are outside this
checkpoint.

## Source audit and decisions

- `AssetScope` owns cancellation and decoded CPU resources. `AssetServices`
  shares in-flight work by URI, request version, result type and loader options.
  Completed requests are not cached. Reuse those services for loading.
- `zyren_gltf` already parses glTF/GLB, resolves relative dependencies and
  delegates meshopt, Draco and Basis decoding to configured codecs. The pipeline
  will supply bytes through `ByteSourceResolver`, without another asset parser.
- Engineering import uses source-owned IDs and a version-pinned sidecar. Preserve
  every input byte, including metadata and sidecars, and keep source ID, source
  revision, requested URI and effective URI in the bundle manifest. A bundle
  digest is a separate identity from the source revision.
- The first format is a bounded JSON container with base64 payloads and SHA-256
  hashes. Serialization is deterministic. You must declare the full resource
  set; glTF validation through an offline resolver detects missing dependencies.
  Response headers are not serialized. Hosts must supply stable source URIs
  without secrets in query parameters.
- Bundles contain original bytes. No optimization or texture conversion is
  claimed. Runtime codec support remains a requirement for compressed inputs.
- Each opened bundle gets its own resolver and asset service pool. Loads stay
  pinned to an immutable bundle snapshot; cache eviction cannot dispose assets
  still owned by a scope.

## Phases and acceptance

1. Build, validate and load a versioned bundle. Require unique source IDs and
   requested URIs, nonempty source revisions, bounded source counts and bytes,
   hashes for each resource and the complete manifest, deterministic serialization,
   and rejection of unsupported schemas or changed payloads. Load a real glTF
   fixture and its external buffer through existing asset services. Test missing
   dependencies, malformed models, cancellation, redirects and cleanup. Keep
   engineering sidecars byte-for-byte intact. Add a runnable package example.
2. Add bounded in-memory offline cache with explicit source-ID and bundle-version
   invalidation, LRU eviction and accounting. Test revised dependencies, old pinned
   scopes, misses, oversized admission and eviction. Persistent disk caching is a
   later step, with atomic writes, corruption recovery and process-safe budgets.
3. Incremental builds. Store dependency hashes and transform/tool versions, reuse
   unchanged outputs, propagate changes through the dependency graph, and test
   interrupted builds and removal of stale dependencies. Reading source bytes is
   still required unless a trusted revision provider can establish freshness.
4. Mesh optimization and LOD. Use explicit adapters to existing codec/tooling APIs;
   preserve material seams, feature IDs, source mappings, skinning and animation.
   Record error bounds and before/after sizes. Acceptance needs geometric fixtures,
   stable picking IDs and native visual comparisons. Decoder availability alone
   does not establish an encoder or simplifier.
5. Compressed texture preparation. Pin encoder and target profiles, preserve color
   space, alpha and mip semantics, and validate outputs with existing texture
   codecs. Check native Metal/Vulkan/DX12 capabilities and fallback profiles using
   actual devices. No browser backend.
6. Persistent offline cache and integration. Add disk byte budgets, pinning,
   recovery, cancellation and eviction telemetry. Integrate optional Studio and
   engineering adapters after their public interfaces settle. Verify application
   reload and device presentation independently of CPU bundle checks.

## Dependencies and shared changes

Use public `zyren` asset services and `zyren_gltf`; use the already-resolved
`crypto` package for SHA-256. No shared core API change is required. The optional `agents.dart` entry point
uses the published `zyren_agents` provider contract.

Requested shared paths: add `packages/zyren_pipeline` to root `pubspec.yaml` and
resolve workspace dependencies under `/tmp/zyren-plugin-expansion.lock`. Preserve
every other workstream's entries and inspect their plans before mutation. Stage
only the pipeline registration hunk if another registration is uncommitted.

Requested shared verification edit: add `packages/zyren_pipeline` to
`tool/check_package_boundaries.dart`, allowing only `zyren_pipeline`, `zyren`,
`zyren_gltf`, `zyren_agents` and `crypto`. Preserve other owners' entries under
the same lock.

## Required runtime agent integration

Follow `agent-runtime.md` and the interaction owner's `zyren_agents` contract.
Expose bounded bundle/source provenance, validation outcomes, load/cache jobs,
limits and explicit invalidation through an optional provider entry point. Use
host-granted scopes and expected revisions for mutations. Keep ordinary asset
services and existing read-only diagnostics intact. glTF metadata enrichment must
use public model/instance APIs and host-supplied stable source bindings, without
inventing persistent IDs from runtime nodes. The shared viewport provider owns
frame/camera/pixel correlation; pipeline provenance cannot establish rendered
visibility. Discovery, schema checks, stale requests, cancellation and disposal
are required automated checks. Native viewport and live MCP evidence remain
separate acceptance checks.

## Checkpoint evidence

Implemented:

- Deterministic schema-v1 container, bounded serial build, manifest/payload hashes,
  offline validation and load through current glTF codecs, immutable source
  snapshots, original-byte CAD sidecar preservation and disk round-trip example.
- LRU cache with payload-byte and entry budgets, explicit source/version
  invalidation and existing-scope lifetime preservation. It is an in-memory
  offline cache. Oversized admission leaves current entries intact.
- Bounded CPU validation/load jobs with progress, cancellation, template release,
  terminal error codes and cleanup. Agent actions call these ordinary commands.
- Optional `PipelineAgentProvider` registered through `zyren_agents`, eight tools,
  bounded public schemas, source provenance, budgets, permission scopes, expected
  revisions and registry retry handling. Attachment disposal unregisters tools
  and drains runtime resources. Cache ownership stays with the host.
- Optional glTF import metadata joins source-owned node bindings to the shared
  viewport provider. Actual triangle picking through the registry carries bundle
  provenance, temporary runtime IDs and explicit unknown pixel visibility.

Automated evidence, pinned SDK `/Users/rexraphael/fvm/versions/3.47.5/bin`:

- `dart analyze packages/zyren_pipeline`: clean after the example lint fix.
- `dart test packages/zyren_pipeline/test --reporter expanded`: 24 tests passed.
  Covers corruption, dependency changes, budgets, cancellation, redirects,
  sidecar bytes, cache eviction/invalidation, job limits and template release.
  Shared-registry checks cover discovery/schema validation, permission denial,
  stale requests, retries, real commands and detach cleanup. A DPR-2 CPU viewport
  pick returns source provenance; removed runtime targets are rejected.
- `dart run packages/zyren_pipeline/example/main.dart`: two sources, 436 original
  bytes, one scene root and zero validation warnings, including disk reload.
- `dart run packages/zyren_pipeline/example/agent_runtime.dart`: registered tool
  discovery and a real glTF validation job reach `succeeded` in process.
- `dart run tool/check_package_boundaries.dart`: pipeline entry is valid. The
  whole-workspace check currently reports two in-progress agent imports in
  `zyren_devtools/lib/io.dart` and `lib/agents.dart` against that owner's allowlist.
  Those files are owned elsewhere and were not rewritten.
- The default Flutter executable uses Dart 3.9.2 and cannot resolve this workspace.
  Pinned Flutter 3.47.5 offline resolution passes. No dependency upgrade was made.

Native/device checks: none for this package. CPU parsing and picking do not
verify Metal/Vulkan/DX12 presentation, texture alpha, custom shader displacement
or rendered pixel visibility. Live MCP transport has not been exercised with this
provider; the shared devtools adapter is being implemented by the interaction
owner. There is no device occupancy conflict because this checkpoint used no GPU
or device session.

Remaining scope: phases 3 through 6, native viewport-to-action validation, live
MCP validation, broader optional glTF import metadata coverage, Studio/engineering
application adapters and publication. Source revisions are host assertions;
hashes prove byte integrity, not publisher authenticity. The complete plugin is
not yet qualified for rollout.

Commits: `aa57bba78d63f5eab343f84f9bde4ef5c152b376` contains bundle build/load.
Cache/runtime/agent checkpoint: `a6a0d1011b316b0922dd17ffb739b34cac5e883e`.
Both commits are local on `main`; nothing was pushed or merged.

## Incremental and disk-cache checkpoint

Phases 3 and the persistent storage portion of phase 6 are implemented. Transform
receipts include input hashes, revisions, locations, media types, immutable
options and pinned tool versions. Reloaded receipts reuse unchanged outputs;
changed dependencies rebuild their dependents, removed steps disappear, and a
cancelled build cannot publish its late result. Original source bytes are retained.

The optional file cache uses flushed temporary files and atomic rename, persistent
pins, archive-byte and entry budgets, hash validation, LRU eviction and telemetry.
A per-directory queue and file lock serialize cooperating processes. Recovery
removes abandoned temporary files and orphan pins, reports corrupt archives and
prunes interrupted evictions. Unpin remains possible after a budget reduction.
The cache requires local filesystem locking and rename semantics; directory fsync
and power-loss durability are not claimed.

Verification: 34 package tests pass, including separate-process cache contention,
receipt reload, dependency propagation, immutable recipes, cancellation, corrupted
archives, pin survival, reduced budgets and stale output removal. Package analysis
is clean. Mesh/texture preparation and native/application integration remain open.
