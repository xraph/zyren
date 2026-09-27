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
legacy scene geometry and temporary transfer buffers are outside these counters;
resident descriptor bytes are not a measurement of total device memory. Command
packets and readback buffers have separate fixed size limits, and the worker
executes commands serially.

## Binary resource protocol, version 2

`fg2_resource_command` uses the renderer handle from the existing native session.
It coexists with the v1 scene ABI. All integer fields are little-endian, with no
implicit struct alignment. Read fields individually after checking each range.

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

## Current integration boundary

The explicit `NativeBackend` implements this API. The Flutter Metal-view and
Android-surface presenters do not yet expose resource scopes. Existing scene
geometry still uses its v1 upload/cache path; material texture sampling, typed
geometry bindings, transform deltas, device recovery and render graph bindings
remain planned work. Allocating a texture does not yet make it usable by a scene
material. Plan 03 task 1 stays open until the scene migration and shared-device
geometry tests pass.

Run `fvm dart run example/resources.dart` from `packages/gpu3d_native` for a native
buffer round trip that retains data after its first scope closes. The GPU suite
also tests partial updates, texture mip readback, budget rejection and cleanup.
