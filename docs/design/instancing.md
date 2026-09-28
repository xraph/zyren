# Instanced meshes

Use `InstancedMesh` when copies share triangle geometry and a built-in material.
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
boxes.count = 1000;
boxes.rotateY(.2);
```

The constructor's `count` allocates fixed capacity and initially displays every
copy. Later assignments to `count` select a prefix, from zero through capacity.
Transform indices address capacity, so you can prepare a hidden copy before
showing it. Use `setTransforms` for bulk edits. The complete range is validated
before publication. Each matrix must be affine and invertible; native submission
also requires finite float32 transforms and inverses.

Transforms are local to the mesh. Its parent hierarchy and ordinary position,
quaternion and scale apply to the whole group. Moving that group, moving the
camera or changing `count` uploads no instance data. `bounds` gives the current
mesh-local union for the visible prefix, including rotation, nonuniform scale
and reflection. Shadow fitting uses those same bounds.

## Uploads and ownership

A native instance occupies 112 bytes: a model matrix and a padded normal matrix.
The normal matrix preserves lighting under nonuniform scale. Reflection signs
preserve material sidedness and tangent handedness within a mixed batch.

The initial upload allocates capacity. Subsequent edits merge dirty ranges and
upload 112 bytes per changed slot. A 64-revision journal bounds bookkeeping;
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
the shared geometry. A separate color per copy is not exposed yet.

Blended instances join the global transparent object sort. Each copy receives
its own depth and draw range, so transparent batching can require one draw per
copy. The sort uses transformed geometry centers and `renderOrder`, with the
same limitations for intersecting transparent surfaces as ordinary meshes.
Changing the camera does not reorder or re-upload the instance buffer.

`ShaderMaterial`, point/line geometry, skinning and morph deformation are not
supported by this profile. Custom shader instancing needs an explicit vertex
contract and remains open. No CPU expansion or browser renderer is selected.

## Run and verify

From `examples/model_viewer`:

```sh
flutter run -d macos -t lib/instancing.dart
flutter run -d <android-device> -t lib/instancing.dart
flutter test integration_test/instancing_test.dart -d macos
```

The demo displays 10000 boxes. “Move one” uploads 112 bytes. “Rotate group”
uploads zero. Count changes preserve storage. The toolbar wraps at narrow widths
and leaves the canvas available for orbit and zoom gestures.

`tool/capture_instances.dart` renders the same scene to a PNG through explicit
native readback. Run it from `packages/gpu3d_native` so the build hook refreshes:

```sh
dart run ../../examples/model_viewer/tool/capture_instances.dart ../../artifacts/native-instancing.png
```

Native tests check the actual draw loop and pipeline cache for 10000 instances,
compare material pixels with ordinary meshes, verify transparent ordering across
mesh boundaries, invalidate shadows after transform edits, and retain independent
versions in two views. Metal and physical Pixel Vulkan presentation checks pass.
Other native targets still need this profile's device qualification.
