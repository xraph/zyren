# Typed asset loading

You load assets through a scope. The request carries its decoder, so a format
plugin does not need a global registry or access to the renderer:

```dart
final task = controller.assets.load(request);
final progress = task.progress.listen(showProgress);
try {
  final asset = await task.result;
  useAsset(asset);
} on LoadCancelled {
  // The caller cancelled or the controller was disposed.
} on AssetLoadException catch (error) {
  showError(error.code, error.issue.sourceUri, error.fieldPath);
} finally {
  await progress.cancel();
}
```

Here, `request` is an `AssetRequest<T>` from your loader. The callbacks belong to
your application. Tasks settle once, and their progress streams close on success,
cancellation or failure. If you update a Flutter widget after awaiting a task,
you still need to follow that widget's mounted rules.

## Services and sharing

Flutter controllers provide bundle, file and HTTP resolution plus native PNG/JPEG
and Radiance RGBE HDR decoding. These services work before you attach a view.
You can override them:

```dart
final services = AssetServices(
  resolver: const FlutterSourceResolver(),
  imageDecoder: const NativeImageDecoder(),
  hdrImageDecoder: const NativeHdrImageDecoder(),
  limits: const AssetLimits(maxTotalSourceBytes: 64 * 1024 * 1024),
  onCleanupError: reportCleanupFailure,
);
final runtime = SceneRuntime.nativeMetal(assetServices: services);
final first = SceneController(runtime: runtime);
final second = SceneController(runtime: runtime);
```

Reuse the same `AssetServices` object when scopes should share pending work. The
default Flutter runtimes already do this. Plain Dart callers can create an
`AssetScope(services: services)` with `NativeSourceResolver`; the core package
does not import Flutter or native libraries.

An in-flight key includes the URI, explicit version, result type, loader type and
loader cache key. The default loader key is that loader instance. If your loader
overrides `cacheKey`, include every decode option in an immutable value. Equal
options may share work across loader instances.

Completed jobs leave the pool. A later request reads the source again, which
avoids silently reusing an old response for a mutable URI. Persistent content
caching belongs in a resolver with explicit version or invalidation rules.

## Cancellation and ownership

Each consumer gets a separate task. Cancelling one removes that consumer. When
its final consumer leaves, the job cancels its source and decode work. You can
retry immediately, even if a cancelled decoder has not returned yet.
A decoder failure also aborts any dependency reads still in progress.

A loader returns `DecodedAsset<T>` with three synchronous ownership callbacks:

| Callback | Responsibility |
| --- | --- |
| `create` | Produce a fresh result wrapper and retain the shared decoded data it needs |
| `release` | Release that wrapper's hold; model templates should reject later instantiation |
| `dispose` | Drop the decoded job's hold after delivery, or when a cancelled job returns late |

Instances must retain the immutable geometry and images they use. Releasing a
template then prevents new instances without invalidating meshes already in a
scene. The native integration fixture exercises this with a bundle image shared
between two templates and two renderer views.

`scope.release(asset)` releases all holds for that exact result identity.
`scope.close()` cancels pending work, releases every held result and returns the
same completion future on later calls. Release failures are collected after the
remaining cleanup callbacks run. Late job disposal and cancellation callback
failures go to `AssetServices.onCleanupError`; they cannot change a task that has
already settled. Keep that reporting callback non-throwing.

## Sources and budgets

`ResolvedSource.effectiveUri` is the base for relative dependencies. Resolve each
reference through `context.readReference`, passing its field path for diagnostics.
For example, a redirect from `/start` to `/models/pump/model.gltf` makes
`../texture.png` resolve under `/models/`.

The default `SourcePolicy` keeps references and redirects within one scheme,
host and effective port. It rejects embedded URI credentials. A bundle URI uses
`asset:///assets/model.glb`; references cannot switch to file or network sources.
Bundle keys also reject encoded path separators, authorities and query strings.
File sources may reference other files under the host's filesystem permissions.
Use a stricter host policy when you need a narrower file namespace. Authentication
and cross-origin sources belong in your host's resolver and policy.
Your app's network permissions still apply. The current native loading fixture
uses bundled assets.

Native HTTP reads validate every redirect before fetching it, limit the redirect
count and apply one deadline to the complete response. They count decompressed
body bytes, including responses without a known length. The implementation uses
Dart's [manual redirect control](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html)
and checks the [response compression state](https://api.dart.dev/dart-io/HttpClientResponse/compressionState.html)
before reporting a total.

Limits apply per decode job. Source reads are deduplicated and admitted serially,
so each dependency sees the remaining aggregate byte allowance. A resolver must
honor its `SourceReadContext.maxBytes` while reading; core also checks the result.
Flutter's bundle API loads a complete entry, so the adapter checks its length
before copying it. That check does not cap the bundle's own allocation.

Use `context.reserveDecodedBytes` before allocating geometry or other retained
payloads. `context.decodeImage` shares that decoded-byte budget and serializes
image admission. These are payload budgets, not a cap on process memory. Format
decoders still need bounds on parser metadata and temporary workspace, and must
put expensive parsing on a worker isolate. Merely returning a `Future` does not
move CPU work off Flutter's UI isolate.

Progress byte counts describe the current operation. A null total stays unknown;
do not turn it into a percentage or assume it is the total for the entire model.

## Preparing data on workers

Build `GeometryData` and `TextureImageData` in your decode worker, then return
them to the caller. These immutable recipes validate and own their input without
allocating scene resource identities. You can publish them cheaply:

```dart
final geometry = BufferGeometry.fromData(decodedGeometry);
final image = TextureImage.fromData(decodedImage);
```

Here, `decodedGeometry` and `decodedImage` are the recipes returned by your
worker. The constructors assign IDs on the caller isolate and reuse validated
storage without another vertex scan or pixel copy. Creating resource identities
inside several workers would allow their independent counters to collide.

Recipes retain no GPU resources. Share a single `BufferGeometry` or `TextureImage`
when instances should share a native allocation. Calling `fromData` twice creates
two resource identities over the same CPU data. Dynamic geometry updates copy
the changed attribute and preserve the recipe and other geometries using it.
An immutable view alone does not transfer ownership; use your worker protocol's
transfer or exit mechanism when moving large recipes between isolates.

## Static glTF models

The optional `zyren_gltf` package exposes `Gltf.asset`, `Gltf.uri`, `GltfOptions`
and scope-owned `ModelAsset` templates. Load through your existing asset scope:

```dart
final task = controller.assets.load(Gltf.asset('assets/models/assembly.glb'));
final model = await task.result;
controller.scene.add(model.instantiate(name: 'Assembly A'));
controller.scene.add(model.instantiate(name: 'Assembly B')
  ..position = const Vec3(3, 0, 0));
controller.assets.release(model);
```

Release stops future instantiation from that template. Existing instances keep
their shared immutable geometry and images. Each renderer retires its GPU
resources after the last visible instance/view no longer needs them. Templates
from two consumers share decoded resources while retaining independent release.
Instances own their transforms and material assignments.

The loader prepares geometry, image copies and scene descriptions on workers.
Only resource identity assignment happens on the caller. Scene selection defaults
to the declared scene, then the first scene; scene-free documents cannot be
instantiated. Names and source diagnostics remain available on the template.

The static material profile imports metallic/roughness triangles, all five maps,
vertex colors and punctual lights. You can select `GltfMaterialMode.unlitDiagnostic`
for an unlit approximation with a warning. Animations, skins, morphs and
unsupported required extensions fail explicitly. See the [fixture-backed support matrix](../../packages/zyren_gltf/README.md)
for the exact limits. The broader renderer and full glTF feature set remain work
in the resource and renderer plan.

For float image data and the RGBE profile, see [HDR assets](hdr-assets.md).
