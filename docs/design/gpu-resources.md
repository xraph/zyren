# Scoped GPU resources

Use `NativeBackend.createResourceScope()` when your plugin needs explicit native
buffers or textures. The scope owns its references. You can retain a resource in
another scope on the same device before closing its original owner.

```dart
final scene = backend.createResourceScope(label: 'scene');
final effect = backend.createResourceScope(label: 'effect');
try {
  final buffer = await scene.createBuffer(BufferDescriptor(
    label: 'positions',
    size: 36,
    usage: {BufferUsage.vertex, BufferUsage.copyDestination},
  ));
  await scene.writeBuffer(buffer,
      Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]));
  final shared = await effect.retain(buffer);
  await scene.close();
  await effect.writeBuffer(shared, Float32List.fromList([2, 0, 0]), offset: 0);
} finally {
  await scene.close();
  await effect.close();
}
```

Import `zyren.dart` for descriptors and scopes, `rendering.dart` for the optional
`ResourceBackend` adapter contract. `RenderFeature.scopedResources` reports this
capability. Flutter's facade exports `GpuTexture` as the alias for the core
`Texture` type, leaving Flutter's widget name available without an import prefix.

The backend closes every owned scope before destroying its worker. Closing stops
new operations immediately and waits for accepted work, then releases every
reference even if an earlier release failed. A handle from a closed scope is
unusable. Keep the handle returned by `retain` to use its surviving reference.
You cannot share allocations between independent native devices.

## Transfers and ownership

Descriptors are immutable CPU values. Creating one allocates no GPU memory.
Buffer sizes and transfers use bytes; sizes, offsets and transfer lengths require
four-byte alignment. Textures currently support RGBA8 linear or sRGB, 2D extents,
one sample and explicit mip levels. Texture uploads replace one complete mip
with tightly packed rows. Copies preserve the encoded channels and alpha;
image decoding, premultiplication and mip generation are separate operations.

Each upload snapshots the supplied typed-data view synchronously. You may edit
or reuse that view after the call returns its future. The worker owns the
transferred packet until native submission. Readback is explicit and returns a
new byte array; `copySource` usage is required. Native row padding is removed
from texture readback, including widths that are not multiples of 64 pixels.

The registry checks renderer identity, device generation, slot and slot generation
before native access. Scope references keep an allocation available. After the
last release it becomes inaccessible immediately, but its bytes remain charged
until its last submission completes. A reused slot increments its generation.
Device failures disable further resource commands and use the renderer's bounded
retirement path.

Metal uploads currently wait for command-buffer status on the worker. This keeps
the existing Metal error checks without transferring Objective-C completion
objects between threads. Vulkan and DX12 submit uploads asynchronously. Explicit
readback and release wait for the latest resource submission, with a two-second
GPU timeout. Batching and narrower per-resource waits remain performance work.

## Limits and accounting

The first resource profile permits 64 MiB of descriptor payload per device,
65,536 registry slots, 4096-pixel texture dimensions and 1024 UTF-8 bytes per label.
Mip bytes count toward the texture allocation. Native validation repeats bounds,
usage and budget checks before GPU allocation or transfer. Failed validation
leaves existing allocations usable.

`resourceStats()` reports live allocation count, resident descriptor bytes and
cumulative successfully submitted upload bytes. Retaining a resource changes none
of these values. Readback doesn't count as upload. Driver padding, frame targets,
and temporary transfer buffers are outside these counters. Scene geometry counts
as one allocation containing vertex and index buffers: 24 bytes per vertex and
four bytes per index, plus 16 bytes per vertex when either UV set is present.
Resident descriptor bytes are not a measurement of total
device memory. Command packets and readback buffers have separate fixed size
limits, and the worker executes commands serially.

## Shared scene geometry

Use `backend.createView()` for an independent readback view on the same native
device. Give each view its own camera and submissions. The views may render
concurrently; the worker serializes GPU access. Closing either view preserves
the other view and its resource scopes. The last close destroys the device.

```dart
final first = await NativeBackend.create();
final second = first.createView();
try {
  await Future.wait([
    first.render(FrameSubmission.capture(scene: scene, camera: cameraA, size: size)),
    second.render(FrameSubmission.capture(scene: scene, camera: cameraB, size: size)),
  ]);
  await first.close();
  // The second view still owns its geometry and can render.
} finally {
  await first.close();
  await second.close();
}
```

An immutable geometry uploads to the GPU once per device while any view owns it.
A view gains ownership when its submission is applied. Hidden objects retain
existing allocations, including objects beneath a hidden parent. Removing an
object from every owning view, or closing its last view, releases the allocation
after submitted work finishes. A newly added hidden object uploads only when
first visible. Captures retain CPU recipes without constructing JSON arrays.
Changing geometry requires a new `BufferGeometry`; transforms and material
values use changed mesh records.

Each view permits one in-flight frame, 4096 meshes and 4096 owned geometry IDs.
A device permits 64 views and 16,384 cached mesh records. Scene allocations share
the 64 MiB resource budget with explicit buffers and textures. Replacement
submissions need room for both old and new allocations until validation succeeds.
A rejected submission preserves the previous view state. Scene readback frame
statistics report actual device upload bytes, including zero for an already
resident geometry received from another view.

The first submission from each view still transfers its CPU geometry recipe to
the worker. Native validation compares immutable data before reusing an existing
GPU allocation. This saves GPU uploads, not every cross-isolate transfer.

## Color textures

Give an unlit or diffuse material a `TextureMap`. You can share one image between
materials with different samplers, and reuse the scene on independent devices.

```dart
final image = TextureImage.rgba(
  width: 1,
  height: 1,
  pixels: Uint8List.fromList([255, 128, 0, 255]),
);
final plane = Mesh(
  PlaneGeometry(width: 2, height: 2),
  UnlitMaterial(colorMap: TextureMap(image: image)),
);
scene.add(plane);
```

`TextureImage.rgba` copies tightly packed RGBA bytes into immutable CPU storage.
Rows and UVs start at the top left. Color images default to `rgba8UnormSrgb`:
sampling decodes sRGB before linear shading, then the output target encodes sRGB
once. Use `rgba8Unorm` when your input already contains linear channel values.
The material's color multiplies the sample; mapped materials default to white.
Alpha is currently opaque, so the shader ignores the image's alpha channel.

Use `SamplerDescriptor` for clamp, repeat or mirrored repeat on each axis and
nearest or linear minification, magnification and mip filtering. You can supply
successive complete mip levels with `mipmaps`. Missing lower levels are not
generated. Changing a sampler or tint does not upload the image again.

`BufferGeometry` accepts optional `uv0` and `uv1` arrays, with two finite values
per vertex. `TextureMap.uvSet` selects 0 or 1 and capture rejects a missing set.
`PlaneGeometry` supplies UV0. Box and sphere UV generation is still pending.

Scene images use the resource registry and share geometry's view ownership rules.
Hiding a mapped mesh retains its image; removing the last owner releases it after
submitted work completes. Supplied mip levels count toward the shared 64 MiB
budget. Each view can own up to 4096 images. `RenderFeature.colorTextures` reports
support. Legacy Dart JSON encoders reject texture materials explicitly.

You can run `lib/textured_scene_demo.dart` in `examples/multiple_views` on macOS
or Android to compare filtering and wrapping through the native presenter.
PNG/JPEG decoding, automatic mips and transparent materials remain task 2 work.

## Binary resource protocol, version 2

`fg2_resource_command` uses the renderer handle from the existing native session.
Scene and resource packets share the header framing. All integer fields are
little-endian, with no implicit struct alignment. Read fields individually after
checking each range.

| Offset | Request header | Response header |
| --- | --- | --- |
| 0 | version, u32, value 2 | version, u32, value 2 |
| 4 | opcode, u32 | status, u32, value 0 |
| 8 | request ID, u64 | echoed request ID, u64 |
| 16 | body byte length, u64 | body byte length, u64 |

The native function returns a resource status code. An error has no response
packet; `fg_last_error` supplies diagnostic text. The Dart adapter checks the
response version, ID and exact byte count. Resource status codes are independent
of the surface API's `Fg2Status` enum.

A key is four u64 values: renderer, device generation, slot, slot generation.
A label is a u32 UTF-8 byte count followed by those bytes. A payload is a u64
byte count followed by exactly that many bytes. Trailing bytes are rejected.

| Opcode | Body | Successful response body |
| --- | --- | --- |
| 1, create buffer | size u64, usage u32, label | key |
| 2, write buffer | key, offset u64, payload | empty |
| 3, create texture | width u32, height u32, mips u32, format u32, usage u32, label | key |
| 4, write texture | key, mip u32, payload | empty |
| 5, retain | key | empty |
| 6, release | key | empty |
| 7, read buffer | key, offset u64, length u64 | raw bytes |
| 8, statistics | empty | resident bytes u64, uploaded bytes u64, live allocations u64 |
| 9, read texture | key, mip u32 | tightly packed raw bytes |

Buffer usage bits 0 through 5 are vertex, index buffer, uniform, storage, copy
source and copy destination. Texture usage bits 0 through 3 are sampled, render
attachment, copy source and copy destination. Texture formats 0 and 1 are
RGBA8 unorm and RGBA8 unorm sRGB. Empty or unknown usage bits are rejected.

## Binary scene protocol, version 2

The render entrypoints accept opcode 11 packets and retain opcode 10 for older
untextured callers. Their header uses a monotonic per-view revision in the
request-ID field. Opcode 11 has this body:

| Order | Value |
| --- | --- |
| 1 | view ID u64, base revision u64 |
| 2 | owned geometry count u32, upload count u32, mesh count u32, update count u32 |
| 3 | view-projection matrix 16 f32, background 3 f32, light direction 3 f32, ambient f32 |
| 4 | owned texture count u32, texture upload count u32 |
| 5 | owned geometry IDs, then owned texture IDs, u32 per entry |
| 6 | texture uploads: ID, width, height, format, mip count, all u32; then each mip's byte length u32 and RGBA bytes |
| 7 | geometry uploads: ID, vertex count, index count, UV flags, all u32; position float3 array, normal float3 array, u32 index array, optional UV0 then UV1 float2 arrays |
| 8 | updates: mesh index u32, geometry ID u32, model matrix 16 f32, color 3 f32, unlit u32, color map flag u32 |

UV flag bits 0 and 1 indicate UV0 and UV1. Material flags are 0 or 1. A color map
flag of 1 appends seven u32 values: texture ID, UV set, wrap U, wrap V, min filter,
mag filter and mip filter. Wrap values 0/1/2 mean clamp/repeat/mirrored repeat;
filter values 0/1 mean nearest/linear. Texture formats match resource commands.
Opcode 10 omits texture counts, IDs, uploads, UV flags/arrays and color map fields.

View IDs and revisions are positive. Base zero replaces the complete draw list;
otherwise it must match the last applied revision and mesh count. Matrices use
column-major order. Every visible mesh must name an owned geometry. Mesh indices
are unique and bounded by the draw list; all floats must be finite. Native
validation also checks colors, normals, indices and invertible model transforms.
Packets are limited to 66 MiB, with at most one million uploaded vertices and
three million indices.

`ScenePacketEncoder` advances only when you call `accept(packet)` after native
application succeeds. A frame whose publication is superseded may already have
applied its scene data; the Metal and Android adapters preserve that distinction.
Rejected and unapplied frames leave the Dart baseline unchanged. The next packet
can retry without losing its geometry uploads.

`fg2_scene_close` releases a view. The scene byte-counter functions include all
resources on its device; they are not total GPU-memory measurements. These
functions are declared in `zyren_resources.h`. Legacy v1 JSON remains an adapter
at the native boundary, backed by the same registry. It keeps its earlier
visibility-based cache behavior and does not support shared view IDs.

## Current integration boundary

The explicit `NativeBackend` implements resource scopes and shared readback
views. Flutter's Metal-view and Android-surface presenters use the same binary
scene protocol and registry, but each presenter still owns a separate device.
They do not yet expose resource scopes or device sharing. Experimental Apple
shared textures also reject `createView()`.

Opaque material texture sampling uses immutable `TextureImage` recipes. Explicit
scope texture handles cannot yet be bound to materials. Dynamic vertex attributes,
device recovery and render graph bindings remain planned work.

Run `fvm dart run example/resources.dart` from `packages/zyren_native` for a native
buffer round trip that retains data after its first scope closes. The GPU suite
also tests partial updates, texture mip readback, budget rejection and cleanup.
Run `fvm dart run example/shared_views.dart` from the same package for the shared
geometry and independent view lifetime example.
