# zyren_pipeline

Build a versioned bundle from your model, external buffers, textures and identity
sidecars, then load it offline through Zyren's existing asset services.

```dart
final bundle = await PipelineBuilder(resolver: yourResolver).build(
  entrySourceId: 'assembly',
  sources: [
    PipelineSource(
      sourceId: 'assembly',
      revision: 'export-r4',
      uri: Uri.parse('asset:///assembly/model.glb'),
    ),
  ],
);
final warnings = await bundle.validateGltf(services: yourAssetServices);
final archiveBytes = bundle.encode();
final restored = PipelineBundle.decode(archiveBytes);
final assets = restored.open(services: yourAssetServices);
final model = await assets.load(restored.gltfRequest()).result;
final instance = model.instantiate();
// Add instance to your scene. Close assets when you no longer need its templates.
await assets.close();
```

Run the disk round-trip example from the workspace root:

```sh
fvm dart run packages/zyren_pipeline/example/main.dart
```

You must declare every external resource needed by the loader. Requested URIs
resolve references; effective URIs preserve redirect bases. A missing dependency
fails offline validation and loading. There is no network fallback. Embedded
resources stay in their original model bytes.

`build` checks the resource set and payload budgets. `decode` also checks hashes
and the container schema. Neither operation validates model semantics. Call
`validateGltf` with your runtime codecs and options to check glTF, and retain its
warnings. Unsupported compression still needs a configured decoder. Validation
covers the resources consumed by that loader configuration; it does not promise
that another codec profile can load alternatives omitted from the bundle.

The bundle version hashes the sorted manifest, including source IDs, revisions,
URIs, media types and payload hashes. A source revision is your upstream version;
it is not replaced by the bundle hash. Models and identity sidecars retain their
exact bytes, so existing source-ID mappings remain usable after a round trip.
Supply stable URIs without secrets in query parameters. Response headers are not
stored, and digests establish integrity rather than publisher authenticity.

`PipelineLimits` bounds source count, individual bytes, total payload bytes and
serialized archive bytes. The JSON/base64 format allocates additional working
memory; those limits are not a process memory cap. Set smaller limits for your
host. The current path is in memory during build and decode.

## Cache and runtime jobs

`PipelineCache` stores immutable bundles under a payload-byte budget and an entry
limit. `get` updates LRU order; `peek` and `bundles` leave recency unchanged.
Call `invalidateSource(sourceId)` when an upstream source changes, or
`invalidateVersion(version)` to remove one bundle. Oversized admission returns
false without evicting existing entries. An open scope keeps its pinned bundle
and decoded assets after eviction.

`PipelineRuntime` adds bounded validation and load jobs. Validation closes its
CPU templates when it finishes. A load job retains its template until you call
`release(jobId)` or close the runtime. You can inspect progress and stable error
codes, cancel running work and await `job.done`. Loading does not insert objects
into your scene. Your host owns scene commands and undo.

Import `io.dart` for `FilePipelineCache`. Give it a dedicated directory, archive
byte budget and bundle limit. It writes through flushed temporary files and
atomic rename, serializes cooperating processes with a directory lock, recovers
interrupted writes, checks hashes on reload and persists pins across restarts.
Pinned bundles resist budget eviction; explicit invalidation still removes them.
`onEvent` reports storage, eviction, corruption and recovery. Local filesystem
rename and locking semantics are required. This is not a network filesystem or
power-loss durability guarantee. Accounting excludes caller-held and decoded data.

## Incremental preparation

`PipelineIncrementalBuilder` reads current source bytes, then runs your explicit
`PipelineTransform` dependency graph in deterministic order. Each transform names
its tool version, options, input IDs and output URI. Its fingerprint includes
input hashes, revisions, media types and locations. Keep transforms pure and pin
all encoder settings. A callback must honor its cancellation token and output
budget; the builder checks both before publishing the new bundle.

Original resources remain intact alongside derivatives and a build receipt.
`PipelineBuildResult.restore(bundle)` restores reuse evidence after disk reload.
Only outputs with the same recipe fingerprint are reused. Removed steps disappear
from the next bundle. A receipt establishes integrity, not publisher trust.
There is no source freshness shortcut: original bytes are reread on every build.

## Runtime agent access

Import `package:zyren_pipeline/agents.dart` to register the optional provider with
the shared `zyren_agents` registry. No network listener is started.

```dart
final runtime = PipelineRuntime(
  cache: PipelineCache()..put(restored),
  services: yourAssetServices,
);
final registry = AgentRegistry(grantedScopes: {'pipeline.load'});
final provider = PipelineAgentProvider(runtime: runtime, instanceId: 'assets');
final attachment = provider.attach(registry);
// Query registry.discover(), then call its versioned tools.
// Dispose the attachment with your plugin and await runtime.close() for cleanup.
```

The provider exposes `status`, `bundles`, `sources`, `jobs`, `start`, `cancel`,
`release` and `invalidate-source`. Queries paginate at 16 items per call.
Source descriptions contain IDs, revisions and hashes. Raw payloads, URIs,
response headers and decoder exception text stay out of transport results.

Your host grants `pipeline.load` for starting jobs, `pipeline.jobs` for cancel
and release, and `pipeline.cache.write` for invalidation. Mutations require the
provider's expected revision and an idempotency key through the registry. They
call the same runtime methods you use directly. Job progress reports bytes and
load stages; a later `jobs` query reports the terminal result. Repeated commands
use the shared registry retry ledger.

Use `PipelineGltfMetadata` from `gltf_metadata.dart` to bind imported node indices
to your stable source object IDs. Pass `pipelineGltfAgentMetadata(import, object)`
through the shared viewport provider's metadata callback. A mesh hit inherits
provenance from its imported ancestor; removed nodes return no enrichment. The
shared provider supplies scene/document/viewport, camera, logical coordinates,
DPR and known presented-frame correlation. Runtime object IDs remain temporary.
Rendered pixel visibility is unknown for this CPU geometry path, including
texture alpha and custom shader displacement.

Run the registry example from the workspace root:

```sh
fvm dart run packages/zyren_pipeline/example/agent_runtime.dart
```

This package retains original bytes alongside declared derivatives. Mesh optimization, LOD generation, compressed
texture encoding and application integration are
tracked in [the workstream plan](../../plans/zyren-plugins/pipeline.md). Native
viewport presentation and live MCP transport have not been verified for this
provider. Package publication is also pending.
