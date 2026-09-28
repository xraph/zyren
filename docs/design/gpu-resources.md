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

Import `gpu3d.dart` for descriptors and scopes, `rendering.dart` for the optional
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
two or four bytes per index, plus 16 bytes per vertex when either UV set is
present. Index-buffer alignment padding is outside descriptor byte counts.
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
Transforms and material values use changed mesh records. Dynamic geometry edits
use the versioned range updates described below.

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

## Dynamic geometry

Create a dynamic geometry when you need to edit its attributes. An update copies
your input, validates complete vertices, then schedules every scene using the
geometry to render. You do not need to set an upload flag or call the renderer.

```dart
final geometry = PlaneGeometry(width: 2, height: 2, dynamic: true);
scene.add(Mesh(geometry, UnlitMaterial()));
geometry.updateAttribute(
  VertexSemantic.position,
  Float32List.fromList([.4, 1, 0]),
  firstVertex: 2,
);
```

The layout and vertex count stay fixed. Position and normal attributes use
`float32x3`; UV0 and UV1 use `float32x2`. `BufferGeometry.fromAttributes` accepts
owned `VertexAttribute` values with an explicit `VertexFormat`. All attributes
must have the same vertex count. Float components must be finite, and normals
must be nonzero. Invalid updates preserve the current revision. An update with
identical bytes does nothing. Static geometry rejects edits.

The core also validates tangent handedness, normalized colors, joint indices and
weights for future material and animation consumers. The current native material
renderer rejects those attributes explicitly. Indices cannot be edited. Create
another geometry to change its layout or topology.

Choose `indexFormat: IndexFormat.uint16` to use two bytes per index, or keep the
`IndexFormat.uint32` default for four bytes. Buffer, plane, box and sphere
constructors accept the same option. Indices are copied into owned immutable
typed storage and must fit both the selected width and the vertex count.
Selecting uint16 rejects values above 65,535 before conversion; it never truncates
them. The format stays fixed across attribute updates and shared GPU copies.

```dart
final compact = PlaneGeometry(
  width: 2,
  height: 2,
  dynamic: true,
  indexFormat: IndexFormat.uint16,
);
```

`geometry.id` stays stable through edits; `revision` advances when bytes change.
A capture keeps immutable CPU data for its own revision. Older captures remain
renderable after edits, including when two views render different revisions of
one geometry. Capturing alone allocates no GPU memory.

Each view tracks the last geometry revision that native rendering accepted.
Edits to hidden meshes wait until the mesh becomes visible. The geometry keeps
64 edits in its change journal, merges overlapping or adjacent ranges, and
uploads a complete version when a view falls behind that journal. Application
code can release older captures to release their CPU arrays.

The native renderer merges dirty rows by GPU buffer: position and normal share
24 bytes per vertex; UV0 and UV1 share 16 bytes per vertex. An exclusive version
reuses its buffers. If another view still owns the base version, the renderer
copies its buffers on the GPU before applying the dirty rows. Resident bytes
then include both versions until the last view advances or closes. Upload
statistics count the dirty CPU-to-GPU rows, excluding GPU-to-GPU copies. All
packet, range and capacity validation completes before existing data changes.

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
The material's `alphaMode` controls whether the image alpha is ignored, tested
against a cutoff, or used for blending.

Use `SamplerDescriptor` for clamp, repeat or mirrored repeat on each axis and
nearest or linear minification, magnification and mip filtering. You can supply
successive complete mip levels with `mipmaps`, or set `generateMipmaps: true`
on `TextureImage.rgba` or `TextureImage.fromImage` to generate the full chain on
the native GPU. Choose one source. Changing a sampler or tint does not upload
the image again.

`BufferGeometry` accepts optional `uv0` and `uv1` arrays, with two finite values
per vertex. `TextureMap.uvSet` selects 0 or 1 and capture rejects a missing set.
`PlaneGeometry`, `BoxGeometry` and `SphereGeometry` supply UV0.

Scene images use the resource registry and share geometry's view ownership rules.
Hiding a mapped mesh retains its image; removing the last owner releases it after
submitted work completes. Supplied and generated mip levels count toward the shared 64 MiB
budget. Each view can own up to 4096 images. `RenderFeature.colorTextures` reports
support. Legacy Dart JSON encoders reject texture materials explicitly.

You can run `lib/textured_scene_demo.dart` in `examples/multiple_views` on macOS
or Android to compare filtering and wrapping through the native presenter.
Use Deform, Shift UV and Reset to edit the same geometry. Dense UV increases
texture repetition; toggle Mips on/off to compare minification. Use
`lib/material_alpha_demo.dart` to compare opaque, masked and blended layers.

### Native mip generation

```dart
final image = TextureImage.fromImage(
  decoded,
  generateMipmaps: true,
  mipmapAlphaFilter: MipmapAlphaFilter.weighted,
);
```

You upload only level zero. Generated levels stay on the GPU, and every level
counts toward the allocation budget before upload begins. `levels` contains the
CPU sources; `descriptor.mipLevels` includes the generated chain. Upload counters
exclude pixels produced by the GPU.

Both formats filter in linear light. sRGB textures decode during reads and encode
when each level is written. The area filter includes the last row and column of
odd extents, including 1-by-N images. `MipmapAlphaFilter.independent`, the default,
averages RGBA channels separately. Choose `weighted` for straight-alpha images
whose invisible texels contain colors you want excluded from smaller levels.
It weights RGB by alpha and returns straight RGBA; fully transparent results have
zero RGB. Alpha coverage preservation for cutout materials is separate work.

For a plugin-owned texture, allocate the desired `mipLevels` with `sampled` and
`renderAttachment` usage, write level zero, then call
`await scope.generateMipmaps(texture, alphaFilter: MipmapAlphaFilter.weighted)`.
Generation replaces all allocated lower levels. Call it again after changing
level zero. A one-level allocation is a no-op, and closing the scope drains an
accepted generation before releasing its resources.

## Material opacity and draw order

```dart
final glass = Mesh(
  PlaneGeometry(width: 2, height: 2),
  UnlitMaterial(
    color: const Color3(.2, .7, 1),
    alphaMode: MaterialAlphaMode.blend,
    opacity: .4,
  ),
);
scene.add(glass);
```

You can use the same settings with `DiffuseMaterial`. Materials are immutable;
replace a mesh's material or use its `copyWith` method to schedule a new frame.
Opacity, cutoff, ordering and depth edits retain existing geometry and images.
`RenderFeature.alphaMaterials` identifies this native capability.

| Mode | Fragment behavior | Automatic depth writes |
| --- | --- | --- |
| `opaque` | Ignore opacity and texture alpha; write opaque color | Enabled |
| `mask` | Discard when opacity times texture alpha is below `alphaCutoff`; surviving fragments are opaque | Enabled |
| `blend` | Source-over blending with opacity times texture alpha | Disabled |

Opacity defaults to 1 and cutoff to .5. Both accept finite values in [0, 1].
A fragment exactly at the cutoff survives. Colors blend in linear light before
sRGB output encoding. Raw image `AlphaMode` describes pixel storage and remains
separate from `MaterialAlphaMode`.

Set `depthWrite: DepthWrite.enabled` or `DepthWrite.disabled` when you need an
explicit override. `DepthWrite.automatic` restores the mode-dependent default,
including through `copyWith`. With `depthTest: false`, depth comparison always
passes; the depth-write policy still applies independently.

Opaque and masked meshes draw before blended meshes. Within each queue,
`mesh.renderOrder` sorts ascending; it defaults to zero and accepts signed 32-bit
integers. Blended meshes with the same order draw back to front using projected
geometry centers, including their current transforms. Scene traversal order
breaks depth ties. Camera movement and position edits update the order without
rearranging captured mesh records or uploading unchanged geometry.

Object sorting does not solve intersecting transparent triangles. Split those
meshes when you need a reliable order; order-independent transparency remains
future renderer work. The canvas is currently opaque. Transparent Flutter
composition still needs a separate output color-conversion path.

## Material sides

Use `side: MaterialSide.front` on `UnlitMaterial` or `DiffuseMaterial` to cull
back faces. `MaterialSide.back` renders the opposite faces, and
`MaterialSide.doubleSided` renders both. Double-sided remains the default for
existing core scenes. A glTF loader must choose `front` unless the source
material enables `doubleSided`.

```dart
final surface = UnlitMaterial(
  color: const Color3(.04, .65, 1),
  side: MaterialSide.front,
);
mesh.material = surface.copyWith(side: MaterialSide.doubleSided);
```

Front winding follows the complete world transform, including mirrored parents.
The renderer reverses normals when lighting back faces. This applies to plain
and textured triangles; expanded lines and points remain double-sided.
`RenderFeature.materialSidedness` reports support. Changing sides uses a mesh
state update and retains its geometry and texture allocations.

Run `lib/material_side_demo.dart` in the multiple-view example to switch sides,
move behind the triangle and mirror its parent. The rules follow
[glTF winding and double-sided lighting](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#double-sided).
Material sidedness alone does not establish glTF material compatibility.

## Built-in texture coordinates

`PlaneGeometry`, `BoxGeometry` and `SphereGeometry` include UV0, so you can attach
a `TextureMap` without supplying coordinates. Box faces each use the full image.
Side faces keep world +Y at the image top; the +Y and -Y faces use -Z and +Z as
their image-up directions.

The Y-up sphere uses longitude for U and north-to-south latitude for V. Its seam
is at +X, with U increasing toward +Z. Seam vertices share exact positions but
retain U=0 and U=1 separately. Each pole triangle has its own pole vertex with U
at the midpoint of its two non-pole vertices.

UVs remain available when you create a geometry with `dynamic: true`. Captures
retain their previous coordinates after edits. A uint32 box now occupies 1,104
native geometry bytes, including the packed UV buffer, even with an untextured
material; switching to a textured material can reuse that same geometry.

## Lines and points

You can draw connected paths, independent segment pairs and camera-facing markers:

```dart
final path = scene.add(Line(
  LineGeometry(points: [Vec3.zero, const Vec3(1, 0, 0), const Vec3(1, 1, 0)]),
  LineMaterial(color: Color3.hex(0x2299ff), width: 4),
));
scene.add(Points(
  PointGeometry(points: [Vec3.zero, const Vec3(1, 1, 0)]),
  PointsMaterial(size: .15, sizeUnits: SizeUnits.world),
));
path.material = path.material.copyWith(width: 8);
```

Use `LineGeometry.segments` for independent pairs or `closed: true` on a connected
path to connect its last point to its first. Point markers default to four-pixel circles;
`PointShape.square` gives you square markers. Both materials support the same
alpha, depth and render-order policies as meshes. They are unlit.

`SizeUnits.pixels` means physical target pixels. World sizes use a camera-facing
plane and shrink with distance. Object transforms move the positions, but object
scale does not multiply stroke width or marker size. Lines clip against the near
plane before expansion. Zero-length projected segments and markers behind the
near plane produce no fragments.

The renderer expands each segment or marker into four vertices and six uint32
indices. Each quad consumes 120 resident bytes; admission checks the expanded size
before allocation and limits a geometry to 250,000 quads. Camera, size and shape
edits reuse that allocation. With `dynamic: true`, position edits create a fresh
expanded buffer and retain old versions needed by sibling views. Triangle geometry
continues to use its smaller dirty-range updates.

Lines currently have butt ends and independent segment quads. Configurable joins,
caps, dashes, textured sprites and antialiased edge coverage remain open. Alpha
sorting orders each `Line` or `Points` object as a whole, so split an object when
you need its individual primitives to draw in a particular order.

Run `lib/primitives_demo.dart` from `examples/multiple_views` on macOS or Android
to compare pixel and world sizes while you move the camera.

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
| 10, generate mips | key, alpha filter u32 (0 independent, 1 weighted) | empty |

Buffer usage bits 0 through 5 are vertex, index buffer, uniform, storage, copy
source and copy destination. Texture usage bits 0 through 3 are sampled, render
attachment, copy source and copy destination. Texture formats 0 and 1 are
RGBA8 unorm and RGBA8 unorm sRGB. Empty or unknown usage bits are rejected.

## Binary scene protocol, version 2

The render entrypoints accept opcode 17 for material sides, opcode 16 for
portable primitives, opcode 15 for alpha/depth/order state, opcode 14
for generated mips, opcode 13 for
compact indices, opcode 12 for
geometry patches, opcode 11 for textures and opcode 10 for older untextured
callers. Their header uses a monotonic per-view revision in the
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

Opcode 12 adds a patch count u32 after the texture counts. After full geometry
uploads and before mesh updates, each patch contains target ID, base ID and range
count (all u32). Each range contains semantic, first vertex and vertex count
(all u32), followed by packed f32 values. Semantics 0/1 mean position/normal with
three components; 2/3 mean UV0/UV1 with two components. The base must be resident
and the target ID must differ. Each patch permits 1 to 64 nonempty ranges,
ordered and disjoint within each semantic. Repeated targets, patch chains,
overflow and missing UV sets are rejected. The renderer bounds resolved CPU
geometry to 64 MiB before cloning it. Full scene validation also applies to the
resolved candidate. A failed patch leaves the accepted view revision unchanged.

Opcode 13 uses the opcode 12 layout, with a patch count that may be zero. Bit 2
of a geometry upload's flags selects uint16 indices; a clear bit selects uint32.
UV flags remain bits 0 and 1. Index values follow the normal array with exactly
the selected width and no alignment padding. Later UV arrays and mesh records
may therefore start at an offset that is not divisible by four. Native decoding
reads checked byte slices and never casts the packet to an aligned structure.
Older opcodes reject the compact-index flag. CPU admission counts expanded
native index recipes separately from compact GPU descriptor bytes.

Opcode 14 extends opcode 13 with a generation mode u32 after each uploaded
texture's source mip count. Zero uses supplied levels, one generates independent
RGBA levels, and two generates alpha-weighted levels. Generated textures must
supply exactly one level. Native admission computes the full chain from the
extent and checks resident bytes before copying the source payload. Older opcodes
keep their existing layout.

Opcode 15 extends opcode 14 with material state after each updated mesh's color
map fields: alpha mode u32, opacity f32, cutoff f32, depth-test u32, depth-write
u32 and render order i32. Modes 0/1/2 mean opaque/mask/blend; depth flags are 0/1.
Dart resolves the depth-write policy before encoding. Invalid modes, flags or
scalar ranges are rejected. Earlier opcodes retain opaque mode, opacity 1, cutoff
.5, depth testing/writes enabled and order zero. Native v1 JSON accepts the same
named fields and resolves an omitted depth-write value from alpha mode.

Opcode 16 adds a topology u32 after each uploaded geometry's UV/index flags:
0 triangles, 1 independent line segments, 2 line strip, 3 points. Each updated
mesh appends primitive kind u32 (0 mesh, 1 line, 2 points), size f32, size units
u32 (0 physical pixels, 1 world) and point shape u32 (0 square, 1 circle) after
its opcode 15 state. Material kind must match geometry topology. Sizes must be
finite and positive, at most 4096 pixels or 1e12 world units. Primitive materials
reject textures and lighting; expanded geometry rejects UVs and patch records.
Dynamic primitives send a complete new recipe. Older opcodes default to triangles.

Opcode 17 appends a side u32 to each updated mesh after its opcode 16 material
state: 0 is double-sided, 1 is front and 2 is back. Other values are rejected.
Expanded primitives require side 0. Earlier opcodes retain double-sided state.
The pipeline selects clockwise front winding when the mesh's world transform
has a negative determinant, and counterclockwise otherwise.

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
functions are declared in `gpu3d_resources.h`. Legacy v1 JSON remains an adapter
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

Run `fvm dart run example/resources.dart` from `packages/gpu3d_native` for a native
buffer round trip that retains data after its first scope closes. The GPU suite
also tests partial updates, texture mip readback, budget rejection and cleanup.
Run `fvm dart run example/shared_views.dart` from the same package for the shared
geometry and independent view lifetime example.

## Decode image files

You can decode a file before creating a scene or GPU device:

```dart
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';

final pixels = await const NativeImageDecoder().decode(
  await File('albedo.png').readAsBytes(),
  limits: const ImageDecodeLimits(maxDimension: 2048),
);
final material = UnlitMaterial(
  colorMap: TextureMap(image: TextureImage.fromImage(pixels)),
);
```

In Flutter, pass `Uint8List.sublistView(await rootBundle.load(assetPath))` to
`decode`. The decoder snapshots your bytes before yielding and runs on a CPU
isolate. You receive immutable, top-down RGBA8 pixels with straight alpha and
an sRGB tag. `TextureImage.fromImage` copies those pixels, strips row padding
and preserves linear or sRGB encoding. It rejects premultiplied input.

Static PNG, including palette and grayscale images, and 8-bit baseline or
progressive JPEG are supported. The JPEG profile accepts at most 64 scans.
16-bit PNG, animated PNG and other image formats are rejected. The decoder
preserves encoded row orientation and channel values; EXIF rotation and ICC
color conversion are not applied. Normalize those assets before loading them.
Texture alpha is retained in CPU data. Set the material's `alphaMode` to mask or
blend when you want rendering to use it.

The default ceilings are 16 MiB of encoded input, 64 MiB of RGBA output and 4096
pixels on either axis. You can lower each limit. `maxWorkingBytes` defaults to
128 MiB per native job, with 256 MiB reserved across active native decodes.
The reservation includes two encoded-input lengths, output/conversion buffers
and decoder workspace. PNG uses the library allocation limit; JPEG uses a
conservative estimate for coefficient and row buffers, so some images below
the dimension ceiling will still exceed their working budget.

This admission budget is not a process-memory cap. Decoder allocator overhead,
Dart isolate transfers, the returned image and later GPU uploads have separate
lifetimes. The native reservation ends when decoding returns. Retain only the
images you need, and choose smaller limits when you process untrusted assets.
The [image allocation limit](https://docs.rs/image/0.25.10/image/struct.Limits.html)
is best effort. Explicit extent, format, CRC and owned-buffer checks supplement
it. JPEG framing is checked before strict decoding, using pinned zune-jpeg
0.5.15 and zune-core 0.5.3. Re-audit workspace accounting when updating them.

At most two decodes may run from one Dart isolate. Excess calls fail with
`ImageDecodeException` and `ImageDecodeError.busy`, without queuing another
copy of the input. Retry when an active decode completes. Malformed data,
unsupported formats/colors and limit failures have distinct error codes;
invalid limit options throw `RangeError` before native work begins.

The C entrypoints in `gpu3d_images.h` require no renderer handle. On success,
`fg2_image_decode` transfers its pixel allocation to the caller. Call
`fg2_image_free` exactly once on that descriptor; it clears the fields and also
accepts a cleared descriptor. The Dart wrapper copies the result into owned
Dart storage and frees native pixels in `finally`, including failure paths.

Run `fvm flutter run -d macos -t lib/textured_scene_demo.dart` from
`examples/multiple_views`, or replace `macos` with your Android device ID.
Tap PNG or JPEG to decode the bundled fixtures and update the native material.
Asset resolution, shared request caching and cancellation remain task 3 work.
