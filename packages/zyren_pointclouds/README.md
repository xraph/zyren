# zyren_pointclouds

Load bounded XYZ samples, render native markers and query the original source
coordinates. You can use this package without Flutter or geospatial services.

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
geometry copies, native expansion and caches have additional costs. Spatial chunks,
streaming and separate GPU admission budgets remain planned work.

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
checks that closing removes their pixels. Metal passed on 2026-10-02. Vulkan,
DX12 and an interactive Flutter screen have not been checked for this package.
LAS, LAZ, E57, spatial LOD and classification filtering are not implemented.

For runtime agents, import `package:zyren_pointclouds/agents.dart` and register a
`PointCloudAgentProvider(cloud: cloud, view: viewportProvider, instanceId: 'scan')`
with your host's `AgentRegistry`. You supply the shared `AgentViewportProvider`,
which names the document, scene and viewport and reports known presentation state.
The provider exposes `inspect` and `pick`; closing the cloud unregisters it.
Use the registry's expected revision and the pick tool's expected camera/frame
fields when you need consistency with a specific view.

These tools are read-only. They return classification bytes only when the source
supplies them, report single-chunk residency, and leave rendered pixel visibility
unknown. The direct registry flow has CPU and Metal offscreen tests. A live MCP
host, geospatial/3D Tiles enrichment and authorized command integration still need
verification. Run `fvm dart run packages/zyren_pointclouds/example/native.dart`
for a native marker image and a source query; it writes `pointcloud.ppm`.
