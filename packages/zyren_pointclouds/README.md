# zyren_pointclouds

Load bounded XYZ, LAS, LAZ and E57 samples, stream native markers and query
the original source coordinates. You can use this package without Flutter or geospatial services.

```dart
final task = assets.load(AssetRequest(
  uri: Uri.parse('file:///survey.xyz'),
  version: 'survey-7',
  loader: const XyzPointCloudLoader(sourceVersion: 'survey-7'),
));
final cloud = ScenePointCloud(data: await task.result);
scene.add(cloud.object);
final hit = cloud.pick(ray, radius: 0.01);
// hit.identity is (sourceUri, sourceVersion, recordIndex).
// hit.sourcePoint retains the source coordinates as doubles.
cloud.close();
```

You supply the coordinate units. Query radius, near and far use world units after
the object transform. A query tests distance from the ray to each sample, with
ties resolved by source record order. It does not test the native marker footprint
or occlusion by other geometry. Pass the active clipping planes and layer mask.

XYZ accepts three finite ASCII numbers per record, blank lines and `#` comment
lines. Extra columns fail explicitly. Source URI, explicit source version and
zero-based record ordinal identify samples; comments do not consume an ordinal.
Programmatic data may carry one classification byte per point. XYZ classification
is unknown, never inferred as class zero.

The default limits are 250,000 points, 32 MiB of input, 1,024 bytes per line and
6 MiB of retained coordinate payload. Core asset limits also apply. These are
payload limits, not a process-memory cap: source transport copies, parser objects,
geometry copies, native expansion and caches have additional costs. Streaming
adds independent decoded, GPU payload and cache admission budgets.

Native positions are relative to the first sample unless you choose an origin.
Creation rejects a cloud whose float32 local positions exceed the display error
limit, which defaults to 0.001 source units. That error describes local coordinate
rounding only. It does not establish survey accuracy or bound camera/transform
arithmetic. Original samples remain available for measurement.

Run the CPU tests with your workspace Flutter SDK:

```sh
fvm flutter test --no-pub packages/zyren_pointclouds/test/cloud_test.dart
RUN_NATIVE_GPU=1 fvm dart test packages/zyren_pointclouds/test/native_test.dart
```

The native test renders two markers, checks their pixels and source query, then
checks that closing removes their pixels. Metal passed. The qualification app
also passed native imports, spatial LOD, classification filtering and zero-readback
Flutter presentation on a physical Pixel 9 Pro using Vulkan. DX12 remains unverified.

For runtime agents, import `package:zyren_pointclouds/agents.dart` and register a
`PointCloudAgentProvider(cloud: cloud, view: viewportProvider, instanceId: 'scan')`
with your host's `AgentRegistry`. You supply the shared `AgentViewportProvider`,
which names the document, scene and viewport and reports known presentation state.
The provider exposes `inspect` and `pick`; closing the cloud unregisters it.
Use the registry's expected revision and the pick tool's expected camera/frame
fields when you need consistency with a specific view.

These tools are read-only. They return classification bytes only when the source
supplies them, report single-chunk residency, and leave rendered pixel visibility
unknown. The streamed provider below adds scoped commands and live MCP evidence.
Run `fvm dart run packages/zyren_pointclouds/example/native.dart`
for a native marker image and a source query; it writes `pointcloud.ppm`.

## Native LAS, LAZ and E57

Import `package:zyren_pointclouds/native.dart` and use
`NativePointCloudLoader(sourceVersion: 'your-version')` with the same asset scope
as the XYZ loader. You can also call `parse(bytes, sourceUri: uri)` directly.
The worker isolate decodes native files and checks cancellation between records.
Cancellation drains the worker before releasing its native job.

LAS 1.0 through 1.4 and LAZ retain double coordinates after scale/offset,
classification, flags, intensity, returns, RGB, GPS time, NIR, extra bytes and
waveform references when present. Metadata retains VLR/EVLR records and CRS WKT.
Waveform sample payloads are not decoded. Units stay unknown unless you interpret
the source CRS. Chunked LAZ requires a valid chunk table; declared chunks and
layer lengths are checked before the decoder allocates their buffers.

E57 retains scan GUIDs, poses, prototypes and raw attribute values. Cartesian or
spherical positions are converted to file coordinates with the scan pose applied.
Coordinates use metres. Invalid positional records are counted and omitted; the
remaining samples retain their original flattened record ordinals. `scanIndex`
and `scanRecordIndex` resolve each point back to its scan. Raw scaled integers
stay available with their prototype scale/offset. Intensity stays float64.

`identityAt` returns the source ordinal. It may differ from the local data index.
`select` preserves that identity and the associated attributes. `PointCloudHit`
exposes both the source identity and `dataIndex` for local attribute lookup.

The default limits admit 250,000 declared records, 32 MiB of source bytes, 6 MiB
of coordinates, 32 MiB of encoded attributes, 4 MiB of metadata and 64 MiB of
native output. Attribute-heavy sources can reach the byte limit first. These are
payload limits, not measurements of total process memory. Isolate transfer,
parser state and Dart objects require additional memory. The asset decoder
reserves its output ceiling before allocation; use smaller per-chunk limits when
loading several chunks concurrently.

Run native-hook tests from this package directory:

```sh
dart test --concurrency=1
cargo test --manifest-path native/Cargo.toml --locked
cargo clippy --manifest-path native/Cargo.toml --all-targets --locked -- -D warnings
```

The synthetic fixture source, licence and regeneration command live in
`test/fixtures/README.md`. Decoder dependency licences are in
`THIRD_PARTY_NOTICES.md` and `licenses`.

## Spatial streaming and source filters

`streaming.dart` exposes `SpatialChunk`, `SpatialStreamer` and
`PointCloudStreamPlugin`. Supply a versioned spatial hierarchy and an asynchronous
loader that honours the supplied cancellation signal. Each manifest node declares
its bounds, geometric error and decoded/GPU payload ceilings. The loader reports
actual payload counts; exceeding a reservation rejects and disposes that result.

Selection uses frustum bounds and projected screen error. A resident ancestor
stays visible until its selected children are ready. Requests outside the current
cut are cancelled, but keep their decoded reservation until they drain. Late
results are disposed. Failed chunks stay failed until you call `retryFailed`.
When a budget cannot admit refinement, the coarse representation remains visible
and `budgetLimited` is true.

Decoded data, visible GPU payload and inactive decoded cache have separate limits.
Active ancestor data counts against the decoded budget. It is retained for
fallback, so allow room for both parent and children during a transition. These
counts exclude renderer cache overhead and do not establish physical GPU residency.

`PointCloudOctree.fromData` builds a bounded offline hierarchy from an existing
cloud. Its coarse levels keep original source samples. It retains those chunks in
memory and is intended for preprocessing and small scenes; use a storage-backed
loader to release source payloads on eviction in a large scene.

The scene plugin attaches native point objects for the visible cut and invalidates
its viewport when loading changes. It holds no continuous frame demand after
settling. `PointCloudFilter` applies classification, intensity and withheld-state
filters to both the native geometry and source queries. An empty filtered chunk
produces no drawable or queryable points. Detach closes the stream by default.
If your host retains it across plugin or engine recreation, set
`closeStreamOnDetach: false` and close it after the host drains.

## Geospatial and live agent integration

Import `geospatial_agents.dart` to use `RealityGeospatialReference`. Declare a
source-to-ECEF affine transform, choose ECEF directly, or create a local ENU frame
from a geodetic origin. Use its group for the rendered source and the same reference
for query enrichment. A LAS or E57 WKT string alone does not establish that mapping.
Arbitrary CRS reprojection and geoid corrections are host responsibilities.

`RealityTilesContext` reads a live `Tiles3DStreamer`: selected/visible tiles,
requests, failures, budgets and payload bytes. Supply `linkForSource` only when you
have a source-record-to-tile association. Feature IDs are verified against the
visible tile instance and its feature set or label. Matching properties are bounded
to 16 KiB. Missing, ambiguous or evicted features remain unverified. The adapter
never infers membership from a URI or reports payload bytes as physical residency.
Wrap point or Gaussian providers in `RealityContextAgentProvider` to add this
context without changing their permission scopes.

Import `stream_agents.dart` for `PointCloudStreamAgentProvider`. Its registered
queries follow the visible, filtered LOD cut. Filter/undo and retry commands require
host-granted `pointclouds.filter` and `pointclouds.retry` scopes respectively. Shared
registry revisions and idempotency keys protect mutations; undo rejects a filter
that the host has since replaced. Registration closes on plugin detach.

The [qualification app](example/qualification/README.md) includes a host-started
shared stdio MCP process, real encoded fixtures and a native Flutter view. See the
[platform evidence](qualification/2026-10-03.md). This is not an independent agent
transport. Physical GPU residency remains unknown.
