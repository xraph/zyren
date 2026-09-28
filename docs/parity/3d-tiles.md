# 3D Tiles streaming

You can stream explicit and nested tilesets with `zyren_3d_tiles`, using ordinary core
meshes and the native renderer. Try the local fixture from `examples/planet`:

```sh
flutter run -d macos -t lib/tiles3d_lab.dart
```

Overview shows the coarse parent. Detail follows an extensionless external manifest to four b3dm buildings over
loopback HTTP. Turn on **Fail downloads** to clear the cache and return HTTP 503
for child content, then use **Reconnect and retry** to refine again. The fixture
needs no credentials. Trackpad navigation uses the existing orbit controls.

For your own scene, load the manifest through a scope, then register the plugin
before mounting your `SceneView`:

```dart
final tileset = await controller.assets.load(
  Tiles3D.tileset(Uri.parse('https://your-host.example/tileset.json')),
).result;
controller.use(Tiles3DPlugin(
  tileset: tileset,
  services: controller.runtime.assetServices,
));
```

Add scene lights for PBR content. You can use local Cartesian coordinates or
ECEF; `GeospatialPlugin` is not required. The loader uses geographic maths only
for region bounds, and the core has no dependency on this package.

## Format and traversal

The supported subset follows the [3D Tiles specification](https://github.com/CesiumGS/3d-tiles/blob/main/specification/README.adoc)
and [b3dm layout](https://github.com/CesiumGS/3d-tiles/blob/main/specification/TileFormats/Batched3DModel/README.adoc):

- Explicit 1.0 and 1.1 trees with arbitrary child counts and inherited ADD/REPLACE.
- Lazy external tilesets, including extensionless JSON and redirects. Nested roots
  inherit the referring transform and refinement. Relative content follows the
  effective document URL; cycles and excessive nested depth are rejected.
- Sphere, box and WGS84 region bounds. Regions ignore tile transforms, including
  at the dateline and poles. Box and sphere bounds use conservative world spheres.
- Affine transform composition with conservative geometric-error scaling under
  nonuniform scale or shear. glTF Y-up conversion precedes RTC translation and
  the tile transform. Camera-relative native rendering retains local precision.
- Direct GLB, JSON glTF and b3dm, decoded by `zyren_gltf`. Its material, image and
  extension support also defines the content limits here. b3dm accepts JSON or
  binary RTC centers and checks table lengths and trailing GLB padding.
- Screen-space-error selection and frustum culling for perspective and orthographic
  cameras. The tileset error controls root appearance; tile errors control
  refinement. Refined branches use an 80% hysteresis threshold.

REPLACE parents stay visible until every selected child branch has coverage.
ADD content remains alongside its descendants. Empty internal nodes remain
traversable even with zero tile error. Whole sibling groups must fit the budget
before selection, so a tight budget can leave the view coarse.

Implicit tiling, multiple contents, viewer request volumes
and unsupported required extensions return `unsupportedFeature`. Optional tile
extensions are also rejected. Batch tables are parsed but do not expose feature
styling or metadata queries. Provider authentication, attribution UI, compression,
fades and the Manhattan/Fuji story configurations remain open.

## Limits and ownership

Manifests default to 4 MiB, 4,096 nodes and 64 levels. Byte, count and depth caps
are checked before the corresponding parser work. Content reads use your
`AssetServices` limits and glTF decoding uses `GltfOptions` limits. The default
URI policy keeps references and redirects on the same origin. Supply credentials
through your resolver; manifest query parameters are not copied to content URIs.

The streamer defaults to four active content jobs, 256 selected nodes, a 64 MiB
CPU cache budget and 128 MiB of visible GPU payload. Reservations are 4 MiB decoded
and 8 MiB resident per tile. Increase these explicitly for larger assets. Actual
geometry and image payloads must fit the reservation, and each cached model keeps
its asset scope until eviction, source replacement or disposal. CPU accounting
uses the decoder's reservations, including unused meshes and alternate scenes.
It can overestimate retained bytes because that ledger also includes temporary
decoded payloads. Visible GPU accounting uses the instantiated scene.

These are logical payload limits. Encoded input, parser arrays, temporary copies,
scene objects and driver overhead are additional; the budget is not a process
memory cap. Cancelled jobs retain their slots and reservations until physical
reads and decoders settle. Give custom resolvers a deadline so an uncooperative
read cannot hold disposal open forever.

Failures expose a typed code, tile ID and attempt count without source URI or
cause text. Retries are explicit and default to three attempts per selected tile.
Replacing the tileset clears its cache and attempts. Disposal removes the plugin
group before waiting for pending work and releases its asset scopes.

## Verification

From `packages/zyren_3d_tiles`:

```sh
dart analyze
dart test --concurrency=1
```

From `examples/planet`:

```sh
flutter test integration_test/tiles3d_streaming_test.dart -d macos
```

Format and scheduler checks cover transforms, region bounds, malformed lengths,
unsupported traversal, URI policy, mixed refinement, empty nodes, eviction,
request cancellation, source replacement and bounded retries. External hierarchy
checks cover redirects, transforms, cycles, retry and disposal. All 25 package
tests pass. The Metal HTTP fixture covers 2,500 pixels at 256 × 192, retains the
parent on HTTP 503, refines to four buildings after retry, resizes to 130 × 250
and releases all resident GPU bytes on disposal.

The Flutter Metal integration test passes at desktop and 390 × 700 logical
sizes. It checks asynchronous status, fallback and retry with zero presentation
readback. After disposal, diagnostics report zero sessions, renderers, retiring
surfaces and held drawables.

This synthetic dataset does not establish production provider compatibility.
Physical-device qualification and upstream story image comparisons remain unrun
for this loader.
