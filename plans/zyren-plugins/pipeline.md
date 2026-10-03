# Asset pipeline

Implementation lives in `packages/zyren_pipeline`; its examples stay inside that
package. The public APIs, persistent cache, pinned preparation worker, agent
providers and optional application adapters are implemented. Broad rollout is
still gated by the device and Studio schema checks listed below.

## Source audit and decisions

- Reuse `AssetScope`, `AssetServices`, `ByteSourceResolver` and `zyren_gltf` for
  cancellation, scoped CPU resources, parsing, relative dependencies and codecs.
  The pipeline adds immutable byte bundles and explicit preparation recipes.
- Preserve source IDs, revisions, requested/effective URIs and exact original
  bytes. Store derivatives beside originals with receipts. Bundle hashes prove
  integrity, not publisher authenticity. Hosts supply URIs without secrets.
- Keep schema-v1 original archive hashes compatible. The manifest processing
  marker distinguishes original resources from prepared bundles. Both variants
  validate manifest and payload hashes on decode.
- Incremental fingerprints include source digests, revisions, locations, media
  types, deeply immutable options and pinned tool versions. Reread original
  bytes on every build. No unverified source freshness shortcut is used.
- Use meshopt 0.6.2 and basisu_c_sys 0.9.1 in a private CPU worker, pinned with
  Rust 1.97.1 and Cargo.lock. Reuse existing runtime codecs and native backends.
  The renderer ABI and other owners' packages are unchanged.
- Keep each material/source primitive separate. Preserve vertex values, seams,
  attributes and deformation data. Static LODs retain source-object identity;
  exact source-triangle mappings apply only to lossless reordering. Skin/morph
  inputs and explicit per-face identities keep their full topology.
- Reuse `EngineeringCadBundle`, `EngineeringImport` and `StudioStore`. Studio
  currently saves groups and boxes; do not invent a parallel imported-mesh schema.
- Native Metal, Vulkan and DX12 remain the rendering targets. There is no browser,
  WebView, OpenGL or software renderer fallback in the native example.

## Phase status

| Phase | Implemented behavior | Verification boundary |
| --- | --- | --- |
| 1. Versioned build/load | Deterministic bounded bundle, hash checks, original CAD sidecar bytes, offline glTF validation/loading and scoped lifetime | CPU fixtures, malformed inputs, missing dependencies, redirects and cancellation pass |
| 2. Memory cache | Payload/entry budgets, LRU, source/version invalidation and pinned scope lifetime | Admission, eviction and old-scope behavior pass |
| 3. Incremental builds | Dependency graph, recipe receipts, reload/reuse, change propagation, removed outputs and cancellation | Rebuild/reuse, immutable options, cycles, bounds and interrupted builds pass |
| 4. Mesh preparation | Cache reordering, exact lossless triangle mapping, attribute-aware static LOD, protected deformation/face identities and error/size receipts | Geometry fixtures and Metal pixel comparison pass; arbitrary animated LOD simplification is deliberately unsupported |
| 5. Texture preparation | ETC1S/UASTC, explicit transfer/quality/mips, codec validation and device-selected transcode targets | All four CPU target formats pass; Metal ASTC/RGBA comparison passes; Vulkan/DX12 device qualification remains open |
| 6. Persistence/integration | Locked atomic file cache, persistent pins, recovery, budgets, telemetry, Studio store and verified CAD import adapters | Independent-process writes and application document reload pass; lab builds for macOS/Android, live presentation checks remain open |

## Runtime agents

`PipelineAgentProvider` exposes bundle/source provenance, budgets, validation/load
jobs, cancellation, release and invalidation. `PipelineBuildAgentProvider` exposes
host-registered recipe IDs, pinned versions, bounded build jobs and receipts.
Agents cannot supply executable paths, shell commands or arbitrary source URIs.
Both providers use the shared registry's scopes, expected revisions, retry ledger,
schemas and disposal contract. Ordinary commands remain usable without agents.

Build admission includes concurrent publication reservations and a retained-payload
budget. Publication failures remain failures. A successful build whose memory
cache declines admission reports `cached: false`. Durable publication belongs to
the host and must fail explicitly when its store rejects an archive.

Imported glTF metadata joins source-owned node bindings to the shared viewport
provider. Native and CPU picks retain temporary runtime IDs separately from stable
source identities. Rendered pixel visibility stays unknown. The native lab records
accepted presentation IDs, but the controller event does not expose captured
scene/camera revisions, so it cannot claim exact frame correlation.

The MCP example uses `serveDevtoolsMcp` and `AgentDevtoolsBridge` from the existing
devtools package. No second transport implementation was introduced.

## Persistence guarantees

The optional file cache requires a dedicated directory on a local filesystem.
Flushed temporary files and atomic rename publish archives; a per-directory queue
and file lock serialize cooperating processes. Pins survive reload. Recovery
removes abandoned writes and orphan pins, reports corruption and prunes interrupted
evictions. Unpinning remains available after budget reduction. Archive and pin
symlinks are rejected. Explicit invalidation can remove pinned entries.

Budgets cover serialized archives or retained bundle payloads as documented. They
do not cover caller-held references, decoded models or total process RSS. Directory
fsync, power-loss durability and network-filesystem semantics are not claimed.

## Optional integration and shared changes

- `engineering.dart`: verifies GLB/sidecar SHA-256 pairing, loads through existing
  offline services and returns `EngineeringImport` bindings for the shared review
  plugin. Byte-pair mismatch fails before import.
- `studio.dart`: implements the shared store with document identity checks and a
  host-provided atomic compare-and-write callback. Disk reload preserves authored
  transforms and review/source identities. Stale saves are rejected.
- `example/native_app`: prepared fixture, original/LOD controls, native texture
  decoding, persistent cache reload, registered source picking, eviction, shared
  ZeroState and restore. It requires native presentation.
- Shared edits are limited to pipeline workspace registration, the owned lab's
  registration and the pipeline package's dependency allowlist. All shared edits
  and commits use `/tmp/zyren-plugin-expansion.lock`. Other work remains untouched.

## Verification, 2026-10-02

Pinned Dart/Flutter: `/Users/rexraphael/fvm/versions/3.47.5/bin`.

- Package analysis passes. The package-boundary/Apple ABI check passed earlier;
  its latest run reports two concurrent point-cloud geospatial imports outside
  that owner's allowlist. The pipeline entry remains valid.
- Full package run with native preparation enabled: 48 tests pass; the separate
  native GPU test is skipped in that run. Three Rust tests and strict Clippy pass.
- Native GPU test passed separately on Apple M3 Max, Metal. The planar fixture
  reduces 512 triangles to 128, reported object-space quadric error
  `0.00006846557516837493`. Original and LOD readback pixels match exactly.
  Device-selected ASTC and RGBA fallback match in the sampled interior region.
  These fixture results do not establish a general Hausdorff or pixel error bound.
- Texture tests cover ETC1S/UASTC, sRGB/linear transfer, transparent/opaque alpha
  endpoints, authored mip count, repeatable local encoding and CPU transcoding to
  RGBA8, BC7, ETC2 and ASTC. Coverage-preserving alpha-test mips are unsupported.
- Live stdio MCP process passes initialize/discovery, native-backed scene setup,
  source-ID pick, read-only denial, real invalidation, retries, stale revisions,
  resulting cache state and EOF cleanup. This is native readback, not app display.
- CAD pairing/import reload and Studio document disk reload/stale-save tests pass.
- macOS debug app and Android debug APK builds pass. The generated fixture version
  is `06690ebeaaed7fcd497be409d750ead4729818f48e8e8b0d6406b9a7dc1216c2`.
- An earlier process-cache test timed out because child `dart run` commands waited
  on concurrent native build hooks. It now invokes the cache-only Dart script
  with the resolved package config; the independent-process contention test passes.

## Remaining qualification and blockers

- Native lab presentation and its desktop/narrow rendered layouts are unverified.
  Other scientific, interaction and planet chats hold macOS presentation sessions.
  The connected Pixel `47121FDAP002C7` was then claimed by the interaction test.
  The pipeline's pending test was stopped during build before device launch.
  Existing sessions were not stopped or replaced.
- Run `integration_test/pipeline_test.dart` on the free macOS/Pixel sessions. It
  checks native presentation, source picking, LOD switching, eviction, visible
  cache miss and restoration. Then inspect screenshots at desktop/narrow sizes.
- Windows/DX12, Linux/Vulkan and Apple mobile device qualification have not run.
- Studio imported-mesh asset slots require its owner's public schema. The adapter
  persists today's supported documents and does not claim imported-asset editing.
- Package publication remains pending. No push, merge or release was requested.

## Local commits

- `aa57bba78d63f5eab343f84f9bde4ef5c152b376`: original bundle build/load.
- `a6a0d1011b316b0922dd17ffb739b34cac5e883e`: cache/runtime/agent checkpoint.
- `2bdbf39c0371c4a3bce7db109095e906f5809cd2`: checkpoint evidence.
- `6c65064`: incremental builds and persistent offline cache.

- `74d07e5`: pinned preparation, build jobs, shared agent adapters and application
  stores, with native readback and live MCP evidence.

- `d5e477b0`: native lab, reproducible fixture, platform builds and qualification
  checklist.

All pipeline changes are committed locally on `main`. Nothing was pushed or merged.
