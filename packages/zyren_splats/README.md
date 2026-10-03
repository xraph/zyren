# zyren_splats

Render anisotropic Gaussian scenes on Zyren native GPUs. You provide float64 source
means, positive-definite 3D covariance, linear RGB and opacity, or import a bounded
32-byte `.splat` source. Perspective and orthographic cameras use the same projected
covariance for rendering and appearance queries.

```dart
final plugin = GaussianSplatPlugin(data: data);
controller.use(plugin);
```

The scene plugin uses the public mesh shader API. It tests opaque scene depth,
blends premultiplied color, follows parent transforms and visibility, and respects
scene section planes. It does not write depth. Each Gaussian uses its mean depth,
including near/far clipping. Intersecting volumes and interleaved transparent meshes
can therefore have ambiguous order. This is appearance, not a measured surface.

The projection is `J C Jᵀ`, with the perspective division included in `J`. Scene
rendering adds a configurable 0.25 pixel-squared variance floor for tiny distant
Gaussians. Fragments outside three standard deviations are discarded. One CPU sort
orders all visible records far to near, retaining each original
`(sourceUri, sourceVersion, recordIndex)` through LOD and merged chunks.

## Streaming and budgets

Import `streaming.dart`. `GaussianOctree.fromData` builds a source-preserving
hierarchy for already-decoded data. `SpatialStreamer` accepts its loader or your
own asynchronous chunk loader with cancellation and declared byte ceilings.
`GaussianStreamPlugin` combines the visible cut into one sorted draw.

```dart
final tree = GaussianOctree.fromData(data, samplesPerChunk: 512);
final plugin = GaussianStreamPlugin(
  stream: SpatialStreamer(root: tree.root, loader: tree.load),
);
controller.use(plugin);
```

Selection uses frustum visibility and screen error. Resident ancestors cover
incomplete child loads. CPU payload, GPU payload, inactive cache, concurrent request
and selected-chunk limits are independent. Cancellation retains reservations until
accepted work drains; late results are disposed. Failed chunks require explicit
retry. Keep room for both a parent and its replacement children.

The default renderer allows 32,768 records and 2 MiB of projected uploads. The
scene allocates a fixed capacity, at 184 bytes per slot for projected values and
carrier geometry. `renderer.gpuPayloadBytes` reports that allocation payload;
stream `gpuPayloadBytes` counts the visible cut. Neither is physical GPU residency.
The default streamed scene caps capacity by its GPU admission budget.

Decoded Gaussian payload accounting is 104 bytes per record, excluding Dart object
and source-identity overhead. An offline octree retains its own chunks even after
a streamer evicts them. Use a storage-backed loader to release source payloads.
Plugins close their streams on detach by default. A host retaining a stream across
engine recreation must set `closeStreamOnDetach: false`, then close it itself.

## Source format

`BinarySplatLoader` reads the headerless 32-byte layout: three float32 means, three
positive float32 scales, four RGBA bytes and four WXYZ rotation bytes. Covariance is
`R diag(scale²) Rᵀ`. Choose `SplatColorEncoding.linear` or `.srgb` explicitly; the
latter converts RGB to linear light. The reader rejects incomplete records,
nonfinite values, invalid rotations and limits before retaining the full source.
Cancellation is cooperative. See the [format implementation](https://github.com/antimatter15/splat/blob/main/main.js).

This format carries no CRS, units, higher-order spherical harmonics or provenance.
You supply the source URI and version. PLY, higher-order harmonics and GPU sorting
are not implemented in this slice.

## Agent and geospatial adapters

Import `agents.dart` for `GaussianAgentProvider.forScene`, or `stream_agents.dart`
for `GaussianStreamAgentProvider`. Register with the shared `AgentRegistry` and
viewport provider. The streamed provider follows the current resident cut and
removes itself on plugin detach. The scene provider reads current replacement data;
bind its registration to `plugin.onClose`.

`inspect` reports source identity and limits. `estimate` returns up to 32 source
records with projected opacity at logical viewport pixels, including DPR and shared
camera/frame guards. These estimates do not establish opaque occlusion, section
clipping, native presentation or Flutter overlay visibility. No splat mutation tool
is registered. `geospatial_agents.dart` exposes the shared declared ECEF/ENU and live
3D Tiles enrichment adapters.

## Offscreen rendering and qualification

`GaussianSplatRenderer.create(owner, data)` remains available for explicit offscreen
images. Its `render(camera: ..., size: ...)` creates and retires frame resources;
its object alone does not join normal scene rendering. This color-only path has no
scene depth and defaults to an exact covariance with no pixel variance floor.

Run package tests from this directory with Flutter 3.47.5:

```sh
RUN_NATIVE_GPU=1 fvm dart test --concurrency=1
```

Metal and physical Pixel 9 Pro Vulkan pixels passed depth occlusion, clipping and
transforms for both camera types. Pixel native presentation, streaming and cleanup
also passed. See [qualification evidence](../zyren_pointclouds/qualification/2026-10-03.md)
for platform boundaries, desktop results and the iOS signing blocker. No DX12 or
Linux GPU qualification is claimed.
