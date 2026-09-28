# Skinning and morph targets

You can deform shared triangle geometry with per-mesh morph weights and a joint
palette. Native vertex shaders apply the morph deltas first, then skinning. The
color and shadow passes use the same function. Source vertices stay on the GPU.

## Morph targets

A `MorphTarget` stores immutable position, normal and tangent XYZ deltas. Each
supplied stream must match the base vertex count. Tangent deltas require a base
tangent attribute and never change its handedness component.

```dart
final geometry = BufferGeometry(
  positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
  normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
  indices: [0, 1, 2],
  morphTargets: [
    MorphTarget(name: 'stretch', positions: [0, 0, 0, 0, 0, 0, 0, 1, 0]),
  ],
);
final mesh = scene.add(Mesh(geometry, StandardMaterial()));
mesh.setMorphWeight(0, .6);
mesh.morphWeights = [-.2];
```

Weights start at zero. They can be negative or exceed one, within the finite
range `[-1000000, 1000000]`. Assigning a list validates and copies the whole list
before publishing a change. Reading `morphWeights` gives an immutable list.
Other meshes sharing `geometry` keep their own weights.

## Skeletons

Use `Bone` for joints or bind ordinary `Object3D` nodes, including imported node
hierarchies. `Skin` stores an ordered joint list and immutable inverse bind
matrices. Geometry supplies four joint indices and four normalized weights per
vertex through `VertexSemantic.joints` and `VertexSemantic.weights`.

```dart
final root = scene.add(Group());
final hip = root.add(Bone(name: 'hip'));
final knee = hip.add(Bone(name: 'knee')..position = const Vec3(0, 1, 0));
final skin = Skin.fromBindPose(
  joints: [hip, knee],
  meshBindMatrix: root.worldMatrix,
);
final character = root.add(SkinnedMesh(geometry, StandardMaterial(), skin: skin));
knee.rotateZ(.4);
character.setMorphWeight(0, .5);
```

In that example, `geometry` must contain the joint and weight attributes and one
morph target. The complete runnable fixture is
[deformation_scene.dart](../../examples/model_viewer/lib/deformation_scene.dart).
For authored bindings, pass `inverseBindMatrices` directly to `Skin`.

Palette matrices map mesh coordinates through
`inverse(meshWorld) * jointWorld * inverseBind`. Capture resolves relative paths
through common ancestors, so moving a whole character preserves its local
palette and avoids unnecessary pose uploads. Joints must belong to the rendered
scene, including hidden skeleton nodes, so their changes reach frame demand.
Animating a joint uses the existing transform tracks and `AnimationMixer`.

Normals use the inverse transpose of the blended joint transform. Tangent
vectors use its linear transform, with reflection applied to handedness. A
singular blend retains the morphed normal instead of dividing by zero. Bind
matrices and submitted joint matrices must be finite, affine and invertible.

## Captures, bounds and uploads

`captureDeformation()` freezes the source revision, morph weights and local joint
palette. Earlier submissions and separate views retain their own versions.
Hidden edits wait until the mesh becomes visible. Rejected native submissions
leave the previous view usable.

`mesh.bounds` is a conservative current bound in mesh coordinates. It combines
morph delta bounds and joint transforms without visiting every deformed vertex
on each frame. Source bounds and joint-index checks are cached by geometry
revision. Shadow fitting and transparent sorting use the current bound.
`InstancedMesh` applies a shared morph pose before each instance transform and
reports the resulting active-instance union.

`mesh.vertexPosition(index)` provides an explicit CPU query for inspection and
future picking. On an instanced mesh, this query returns the shared deformed
vertex before the instance transform. Rendering never selects a CPU fallback.

Each pose upload uses `272 + 64 * jointCount` bytes, including space for 64 morph
weights. A two-joint pose uses 400 bytes. Geometry keeps joint/weight rows at 32
bytes per vertex and dense morph position/normal/tangent rows at 36 bytes per
vertex per target. Editing a deformable source geometry currently uploads a full
source revision. Animating its pose leaves that source resident.

## Limits and current coverage

Native backends advertise `RenderFeature.skinning`, `RenderFeature.morphTargets`,
`maxJoints: 256` and `maxMorphTargets: 64`. The geometry and pose buffers share the
64 MiB scene/resource budget. Exceeding a capability or limit fails explicitly.

Unlit, diffuse and standard triangle materials support deformation, including
UV maps, vertex colors, tangent normal maps, transparency and shadows. Morphs
also work with `InstancedMesh`. Separate skeletal palettes per instance,
`ShaderMaterial` deformation, expanded lines/points and extra joint influence
sets are not supported yet. The glTF loader still rejects skin/morph content;
imported bindings and animated morph-weight tracks are the next layer of work.

The ordering follows the [glTF morph and skin specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
and [Khronos skinning tutorial](https://github.khronos.org/glTF-Tutorials/gltfTutorial/gltfTutorial_020_Skins.html).
This checkpoint does not establish full Three.js or Takram parity.

## Run

From `examples/model_viewer`:

```sh
flutter run --release -d <android-device> -t lib/deformation.dart
flutter run -d macos -t lib/deformation.dart
flutter test integration_test/deformation_test.dart -d macos
```

Both meshes share geometry. Playback, pose, speed and width controls affect the
blue mesh; the orange mesh keeps its own pose. Pausing releases frame demand.
The controls wrap at narrow widths while leaving the canvas visible.

From `packages/gpu3d_native`, use explicit readback to save the reference scene:

```sh
dart run example/deformation.dart ../../artifacts/native-deformation.png
RUN_NATIVE_GPU=1 dart test test/deformation_test.dart --concurrency=1
cargo test --manifest-path native/Cargo.toml --test deformation_render -- --include-ignored
```

## Animated weights

Use `MorphWeightKeyframeTrack` to animate a mesh's complete weight vector with
step, linear or cubic spline interpolation. The track copies keys and tangents,
so you can share a clip between model instances. `AnimationProperty.morphWeights`
identifies this channel; `TransformProperty` remains an alias for existing code.

A mixer binds a mesh directly when you include it in `nodes`. For a model node
with several primitives, pass `morphTargets: {'node:0': [first, second]}` alongside
that node's entry. Each primitive retains its own rest weights. Stopping the
last action restores them, and weighted actions blend against those rest values.
The mixer checks every sampled transform and weight before publishing a pose.
