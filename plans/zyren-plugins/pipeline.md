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
`crypto` package for SHA-256. No shared core API change is required.

Requested shared paths: add `packages/zyren_pipeline` to root `pubspec.yaml` and
resolve workspace dependencies under `/tmp/zyren-plugin-expansion.lock`. Preserve
every other workstream's entries and inspect their plans before mutation. Stage
only the pipeline registration hunk if another registration is uncommitted.

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

First implementation: deterministic versioned container, bounded serial build,
integrity validation, offline glTF validation/load through current codecs,
immutable source snapshots and a disk round-trip example. Original model bytes
and the existing CAD identity sidecar survive the container round trip unchanged.

Pinned SDK: `/Users/rexraphael/fvm/versions/3.47.5/bin`. The default Flutter path
uses Dart 3.9.2 and cannot resolve this workspace; pinned offline resolution passes.
`dart analyze packages/zyren_pipeline` passes and the 11 bundle tests pass,
including the existing converted CAD fixture. Cache and agent checks are next.
No native/device check or package publication has been performed. Native
presentation, agent/MCP integration and phases 3 through 6 remain unverified.
The disk round-trip example passes: two sources, one scene root and zero warnings.
First implementation commit: this checkpoint commit; exact ID recorded next.
