# Zyren geospatial

Geospatial coordinates, globe controls, terrain streaming and atmospheric
rendering for Zyren's native renderer. Add `GeospatialPlugin` before plugins
that depend on its ellipsoid reference.

## Terrain imagery

Wrap your terrain source to apply geographic or Web Mercator imagery:

```dart
final imagery = TemplateImagerySource(
  baseUri: imageryEndpoint,
  template: '{z}/{x}/{y}.png',
  datasetId: 'survey-2026',
  services: assetServices,
  attribution: 'Your imagery provider',
);
final terrain = TerrainPlugin(
  source: ImageryTerrainSource(
    terrain: elevationSource,
    layers: [ImageryLayer(imagery)],
  ),
);
```

Supply a resolver and CPU image decoder through `AssetServices`. Keep credentials
in your resolver; dataset IDs and versions are public labels. Templates support
`{z}`, `{x}` and `{y}`. URLs default to north-origin XYZ rows; set
`urlScheme: ImageryUrlScheme.tms` for south-origin rows. The public coordinates
remain south-origin in both cases.

Imagery is reprojected into the terrain's existing geographic UVs on a CPU
worker. Geometry, skirts and picking stay intact. Layers use linear-light,
premultiplied-alpha composition and retain their order. You can configure up to
four layers, each with an opacity and a level offset. Set a positive offset when
a regional terrain source starts at level zero but its imagery uses global zooms.
Web Mercator imagery leaves polar regions covered by the terrain's base image.

`outputSize` defaults to 256 and can be 2-2048. Source tiles must match their
declared square `tileSize`. The source reduces imagery detail until the region
fits `maxTilesPerLayer` (2-16, default 4). Upload and decoded payload estimates
include composition storage and generated mips. These limits do not cap process
memory. CPU decoding and composition each admit two jobs per caller isolate,
with sixteen queued jobs; canceled physical work keeps its reservation until it
settles.

The terrain scheduler retains parent coverage until child geometry and imagery
both load. Failed reads appear in `TerrainPlugin.failures`; call `retryFailed()`
after fixing access or connectivity. Display `TerrainPlugin.attributions` beside
the viewport. It contains credits for visible terrain and imagery, excluding
zero-opacity layers.

Native tests use local HTTP fixtures for decoding, parent fallback, retry and
resource cleanup. Provider access and provider-specific requirements need their
own live qualification.
