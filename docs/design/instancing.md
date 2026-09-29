# Instanced meshes

Use `InstancedMesh` when copies share triangle geometry and a material.
Opaque and masked copies use one native indexed draw per mesh. You can update a
copy without rebuilding its geometry or changing the other transforms.

```dart
final boxes = scene.add(InstancedMesh(
  BoxGeometry(),
  StandardMaterial(baseColor: const Color3(.1, .55, .8)),
  count: 10000,
));
boxes.setTransforms(0, List.generate(10000, (i) => Mat4.compose(
  Vec3((i % 100).toDouble(), 0, (i ~/ 100).toDouble()),
  Quat.identity,
  Vec3.one,
)));
boxes.setTransform(42, Mat4.compose(
  const Vec3(42, 3, 0), Quat.identity, Vec3.one,
));
boxes.setColor(42, const Color3(1, .2, .1));
boxes.count = 1000;
boxes.rotateY(.2);
```

The constructor's `count` allocates fixed capacity and initially displays every
copy. Later assignments to `count` select a prefix, from zero through capacity.
Transform indices address capacity, so you can prepare a hidden copy before
showing it. Use `setTransforms` for bulk edits. The complete range is validated
before publication. Each matrix must be affine and invertible; native submission
also requires finite float32 transforms and inverses.

Use `setColor(index, color)` or `setColors(first, colors)` for per-copy tints.
`getColor(index)` returns the current linear RGB value. White is the default
and leaves the material unchanged. The tint multiplies base material, texture
and vertex RGB without changing opacity or emissive light. Channels must be
finite and between zero and one. An invalid color rejects the entire range;
captured frames keep their previous colors. Color indices address capacity,
including hidden copies, just as transform indices do.

Transforms are local to the mesh. Its parent hierarchy and ordinary position,
quaternion and scale apply to the whole group. Moving that group, moving the
camera or changing `count` uploads no instance data. `bounds` gives the current
mesh-local union for the visible prefix, including rotation, nonuniform scale
and reflection. Shadow fitting uses those same bounds.

## Uploads and ownership

A native instance occupies 128 bytes: a model matrix, padded normal matrix and
padded RGB tint.
The normal matrix preserves lighting under nonuniform scale. Reflection signs
preserve material sidedness and tangent handedness within a mixed batch.

The initial upload allocates capacity. Subsequent edits merge dirty ranges and
upload 128 bytes per changed slot. Transform and color edits share dirty ranges,
so overlapping edits upload each slot once. A 64-revision journal bounds bookkeeping;
older captures use a full upload when the journal cannot describe their changes.
Captured frames own immutable versions. Exclusive versions reuse GPU storage;
shared views retain the older buffer until their owners advance or close. Hidden
edits wait until the view needs the instances again.

The native backends advertise `RenderFeature.instancing` and
`DeviceLimits.maxInstances` of 100000 slots per view. Hidden capacity counts
against this limit. Instance buffers share the device's 64 MiB scene/resource
budget with geometry and images. Unsupported capabilities fail before rendering.

## Materials and ordering

Unlit, diffuse and standard materials support instances, including UV maps,
tangents, vertex colors, masks, PBR lighting and shadows. Vertex colors belong to
the shared geometry; instance tints multiply them. Color changes retain the
geometry and material pipeline.

Blended instances join the global transparent object sort. Each copy receives
its own depth and draw range, so transparent batching can require one draw per
copy. The sort uses transformed geometry centers and `renderOrder`, with the
same limitations for intersecting transparent surfaces as ordinary meshes.
Changing the camera does not reorder or re-upload the instance buffer.

Shared [morph deformation](deformation.md) applies before the instance transforms.
[`ShaderMaterial`](shader-materials.md) uses an explicit instanced geometry
profile. Its public WGSL input exposes the tint at vertex location 13; your
shader decides how to apply it. Point/line geometry and a separate skin palette
per instance remain unsupported. No CPU expansion or browser renderer is selected.

Scene packet opcode 26 carries RGB beside each uploaded or patched transform.
The native decoder accepts earlier instance packets with white tints. Invalid
colors, truncated records and ranges outside capacity reject the packet before
the renderer publishes its next resource version.

## Run and verify

From `examples/model_viewer`:

```sh
flutter run -d macos -t lib/instancing.dart
flutter run -d <android-device> -t lib/instancing.dart
flutter test integration_test/instancing_test.dart -d macos
```

The demo displays 10000 boxes. "Move one" uploads 128 bytes. "Rotate group"
uploads zero. Count changes preserve storage. The toolbar wraps at narrow widths
and leaves the canvas available for orbit and zoom gestures.

The shader lab's `lib/geometry.dart` demo also exposes a palette button. It changes
twelve differently transformed ribbons while retaining two scene draws and the
existing material programs.

`tool/capture_instances.dart` renders the same scene to a PNG through explicit
native readback. Run it from `packages/zyren_native` so the build hook refreshes:

```sh
dart run ../../examples/model_viewer/tool/capture_instances.dart ../../artifacts/native-instancing.png
```

Native tests check the actual draw loop and pipeline cache for 10000 instances,
compare material pixels with ordinary meshes, verify transparent ordering across
mesh boundaries, invalidate shadows after transform edits, and retain independent
versions in two views. Metal and physical Pixel Vulkan presentation checks pass.
Other native targets still need this profile's device qualification.
