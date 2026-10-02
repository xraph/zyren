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

## Terrain metadata

`QuantizedMeshTerrainSource` supports EPSG:4326/TMS layers with static ranges or
`metadataAvailability`. Dynamic layers start with two roots. A validated mesh
response makes its advertised descendants available on the next selection pass;
`availabilityOf()` distinguishes unknown coverage from an unavailable tile.
The source requests advertised normals, water masks and metadata through both
Accept and the extensions query parameter.

Sparse siblings retain their parent. Fill tiles and `parentUrl` layer stacks are
not supported. Availability is stable for a source version: a changed metadata
page fails rather than mixing generations. Replace the source when the dataset
changes. Missing required metadata also fails and follows the normal retry path.

You can set `maxAvailabilityPages` and `maxAvailabilityRanges` when opening a
source. Defaults are 1,024 pages and 16,384 ranges, retained for the source lifetime
separately from the tile cache. A full metadata store stops further refinement
with a limit error. Each mesh also has `maxMetadataBytes` (64 KiB by default) and
`maxMetadataRanges` (1,024) decoder limits. Payload reservations include masks,
parsed ranges and credits; temporary JSON parsing is bounded by bytes and depth.

`TerrainTile.waterMask` contains one uniform byte or a north-first 256 by 256
coverage grid, where 0 is land and 255 is water. Values between them preserve
soft coastlines. `TerrainTile.availability` retains immutable relative-level
ranges. Imagery composition preserves both fields and the provider's credits.
These are CPU values; a water mask alone does not add a reflective water pass.

## Draped overlays

Wrap your imagery source with `OverlayTerrainSource` to tint water and draw
polygons or lines on the terrain:

```dart
final source = OverlayTerrainSource(
  terrain: imageryTerrain,
  overlays: [
    WaterTintOverlay(color: Color3.hex(0x247ba0), opacity: 0.6),
    TerrainPolylineOverlay(
      points: surveyBoundary,
      color: Color3.hex(0xffdd55),
      width: 3,
    ),
  ],
);
```

Layers draw in list order. `TerrainPolygonOverlay.rings` starts with an outer
ring, followed by holes. Supply `Geodetic` coordinates; heights are ignored
because these shapes drape on the existing mesh. Segments are straight in
longitude/latitude, take the shorter path across the dateline, and clip at tile
edges. Split paths that span half the globe or more. Polygon filling uses the
even-odd rule within each ring and subtracts holes.

Line width is in output texture pixels, so its ground width changes with terrain
level. Lines have round caps and joins. Vector edges use four coverage samples
per pixel, and all layers blend in linear light. Water tint uses the provider's
soft coverage mask; without a mask that layer has no effect. It does not animate
waves or reflections. Picking still returns the terrain mesh.

Use `outputSize` (2-1024, default 256) to set the texture resolution. A source
accepts up to 64 overlays and 4,096 vertices, subject to `maxSampleTests`
(default 64 million). The conservative work estimate rejects oversized jobs
before requesting terrain. Imagery and overlays share two CPU worker slots and
sixteen queue positions. Geometry, skirts, metadata and credits remain owned by
the terrain tile. Replace the source to change its immutable overlays.

## Atmosphere table decoding

`AtmosphereTableDecoder` reads raw little-endian RGBA half floats and single-part
scanline EXR files with RGBA HALF channels, full sampling and NONE, ZIPS or ZIP
compression. Supply the expected width, height and depth. EXR rows reverse before
the image is reshaped into volume slices, matching the source loader.

Decoded tables own immutable bytes. Encoded and decoded limits are checked before
allocation, and ZIP output cannot exceed its declared scanline storage. Invalid
headers, duplicate channels or chunks, truncated data and nonfinite samples fail
with a typed load error. Tiled, multipart, deep and other compression profiles
are unsupported. This decoder does not upload a texture by itself.

The optional reference test uses `ZYREN_SOURCE_LUTS` to compare the five pinned
binary/EXR pairs. The upstream exports differ by up to one half-float step, so
that comparison allows one step instead of requiring identical bytes.
