# Remote quantized-mesh terrain

You can load a static terrain layer with `QuantizedMeshTerrainSource.open`, then
pass it to `TerrainPlugin`. The adapter uses the same scheduler and native meshes
as the offline terrain source. No renderer changes are needed.

```dart
Future<TerrainPlugin> loadTerrain(
  Uri layerUri,
  ByteSourceResolver resolver,
  LoadCancellation cancellation,
) async {
  final source = await QuantizedMeshTerrainSource.open(
    uri: layerUri,
    datasetId: 'my-public-dataset-id',
    resolver: resolver,
    cancellation: cancellation,
  );
  return TerrainPlugin(source: source);
}
```

Register `GeospatialPlugin()` before the returned terrain plugin. Use
`NativeSourceResolver` from `zyren_native` for file, HTTP and HTTPS reads, or your
own resolver for authentication and request headers. You can also use the Flutter
resolver. Keep cancellation alive for the manifest request; the scheduler supplies
a separate signal for each tile. The camera can opt into reversed depth.

## Supported format

The decoder follows the [quantized-mesh 1.0 binary layout](https://github.com/CesiumGS/quantized-mesh)
and the adapter reads its [layer.json manifest](https://github.com/CesiumGS/quantized-mesh/blob/main/SPECIFICATION.md).
Supported layers use EPSG:4326, TMS coordinates, two geographic roots and a finite
maximum level. Static availability rectangles are optional. Without them, the
source treats every tile through `maxzoom` as available.

Both index widths work, including the alignment change above 65,536 vertices.
The decoder expands delta/zigzag coordinates and high-water indices, sorts edge
lists for skirts, and converts positions relative to a double-precision ECEF
origin. UV zero is north. It uses advertised oct normals when supplied and
computes area-weighted normals otherwise. Unknown extensions are length-checked
and skipped. Water masks are not rendered.

Missing siblings keep their parent. We don't generate fill geometry yet, so a
partially available branch intentionally stays coarse. Parent layers, dynamic
metadata availability, nonzero minimum zoom and other projections or schemes
return `unsupportedFeature`. Malformed data returns `invalidData`.

## Limits and ownership

Default tile limits are 1 MiB of encoded data, 8,192 surface vertices, 16,384
triangles and 2,048 edge vertices across four edges. Each edge must include both
corners. Counts and lengths are checked before allocation. The geometry limits
also apply when you increase these defaults. Manifest reads default to 1 MiB,
with at most 4,096 availability rectangles and zoom levels from 0 to 30.

The default height envelope is -12,000 to 10,000 metres, with 50-metre skirts.
Decoded heights must stay inside it. Culling bounds use that envelope, including
skirts, rather than trusting the downloaded bounding sphere. You can configure
the envelope and skirt depth before loading. `levelZeroGeometricError` defaults
to 100,000 metres and halves per level; this is a host estimate because the tile
format does not carry geometric error.

CPU and GPU reservations cover maximum final payload sizes. Temporary parser
arrays, geometry copies, compressed input buffers and allocator overhead are
additional. Count limits bound this work, but the scheduler budget is not an RSS
cap. Decoding is synchronous; worker-isolate decoding remains open.

The default URI policy keeps references and redirects on the same origin.
Relative templates resolve against the effective manifest URL. Credentials from
the manifest query are not copied to tile URLs. If your server needs an Accept
header or authentication, supply it through your resolver. Errors retain their
typed code but discard URI and cause text that could contain credentials.
Source identities include the public dataset ID, version and attachment instance.
Dataset IDs and versions accept 1 to 128 ASCII letters, digits, dots, underscores
or hyphens. Tile templates must include `{z}`, `{x}` and `{y}`.

Terrain currently uses a neutral one-pixel texture. Provider imagery, filtering,
dynamic availability, parent layers, Ion token exchange and 3D Tiles are separate
work. This adapter has not been qualified against a production terrain service.

## Verification

From `packages/zyren_geospatial`, run:

```sh
dart test --concurrency=1
dart analyze
```

The checked suite has 130 tests. New checks cover reservation overflow, malformed
headers, every truncation of the small fixture, hostile counts, index alignment, edge membership,
oct normals, local precision, manifest policy, polar/dateline bounds and
cancellation after an uncooperative resolver returns. Loopback HTTP tests exercise
gzip, failed requests, retry and cancellation during a pending response.

The native Metal fixture downloads synthetic terrain through HTTP and renders it
with `TerrainPlugin`. At 256 × 192 it covers 14,886 pixels. It retains parents on
HTTP 503, refines after retry, replaces its source, resizes to 130 × 250 and releases
all resident GPU bytes on disposal. This is protocol and renderer evidence, not
provider-data or mobile qualification. No physical-device run was made for this
adapter.
