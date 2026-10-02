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

This package stores original bytes. Mesh optimization, LOD generation, compressed
texture encoding, incremental transform reuse and persistent offline caching are
tracked in [the workstream plan](../../plans/zyren-plugins/pipeline.md). No native
presentation check or package publication is implied by the CPU example.
