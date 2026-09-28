# Tangent generation

Flutter's default asset services prepare missing glTF normal-map tangents with
MikkTSpace. You don't need a renderer to prepare geometry. For a standalone Dart
loader, configure the CPU service alongside your image decoder:

```dart
final assets = AssetScope(
  services: AssetServices(
    resolver: NativeSourceResolver(),
    imageDecoder: NativeImageDecoder(),
    tangentGenerator: NativeTangentGenerator(),
  ),
);
```

You can also prepare core geometry directly:

```dart
final prepared = await const NativeTangentGenerator().generate(data, uvSet: 1);
final mesh = Mesh(geometry: BufferGeometry.fromData(prepared), material: material);
```

The core owns `TangentGenerator`, `TangentGenerationLimits` and immutable
`GeometryData`. The native package implements that service on a CPU isolate.
The glTF plugin only sees the core interface. Geospatial can use the same service
without adding a dependency from the core to geospatial.

## Geometry and loading rules

Tangents belong to triangle corners. If two corners share a vertex but disagree
on tangent direction or handedness, `withCornerTangents` creates separate
vertices. It copies every attribute in its original format, including byte
colors and joint indices. Equal corners keep their shared index. Unused vertices
are removed and output uses the smallest supported index width.

The glTF loader generates tangents only when a normal map needs them and the
prepared primitive has no authored tangents. It uses that map's UV set. Authored
tangents with authored normals pass through unchanged. If normals are missing,
the loader first creates flat normals and discards authored tangents, as required
by the [glTF specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes).
A missing generator produces an actionable error at the primitive's TANGENT path.

The native implementation uses Mikkelsen's pinned reference algorithm with its
default 180-degree threshold. Normals are normalized for calculation. Source
geometry is unchanged. The [vendor note](../../packages/gpu3d_native/native/vendor/mikktspace/README.md)
records the bounded execution changes and original license.

## Admission and cancellation

You can lower limits through `AssetLimits.tangents` or the direct generator call.
The output ceiling is 128 MiB and one million vertices. Native scratch has a
128 MiB ceiling per job and a shared 256 MiB reservation pool. Each reference loop
condition charges a budget of at most 100 million iterations. Recursive depth is
limited to 256. Exceeding a limit returns a typed error and releases scratch.
Positions and UV coordinates must be finite and within +/-1e15; invalid generated
bases are rejected before publication.

These are payload and native scratch limits, not a process-memory ceiling. Dart
geometry copies, remapping tables and caller-owned FFI buffers add temporary
storage. Two jobs per Dart isolate can be active. Native scratch admission also
applies across isolates.

Asset scopes serialize image decoding and tangent preparation against the same
remaining decoded-byte budget. They account for the complete replacement
geometry, including seam copies. Cancellation prevents admission and publication;
an already running native call finishes within its execution limits before its
worker storage is reclaimed.

## Delivery checks

The implementation is checked in layers: core seam remapping and attribute
preservation, native reference vectors and bounded failures, loader service
selection and diagnostics, then native normal-map pixels on Metal and Vulkan.
The viewer includes a Normal map sample with generated tangents. Its Metal and
Pixel Vulkan integration checks pass. A bundled AOT capture also renders it
without a Flutter window. Broader material reference coverage remains part of Task 5. This feature does not
close the full Three.js or Takram port.
