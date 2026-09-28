# gpu3d

Build scenes, geometry and plugins in Dart without a Flutter engine or GPU.

```dart
import 'package:gpu3d/gpu3d.dart';

final scene = Scene()..add(Mesh(BoxGeometry(), DiffuseMaterial()));
final camera = PerspectiveCamera();
final snapshot = scene.snapshot(camera, 1);
```

You supply a `rendererFactory` when creating the core `SceneEngine`. Use
`gpu3d_native` for a native backend or `flutter_gpu3d` for Flutter views and the
native default. Geospatial remains an optional package.

Advanced output and backend contracts are in `package:gpu3d/rendering.dart`.
Scenes default to a transparent canvas. Set `scene.background` for a color fill,
and `backgroundOpacity` for partial coverage. Mesh materials support opaque, mask
and blend modes. The larger API design is still being implemented. Run this package's tests with `fvm dart test` after resolving
the workspace dependencies.

## Vertex colors

You can add `VertexSemantic.color` to `BufferGeometry.fromAttributes` and opt
in with `UnlitMaterial(vertexColors: true)`. Diffuse, standard, line and point
materials accept the same flag. Your existing geometry and material can still
be shared across meshes.

Use float RGB, float RGBA or normalized byte RGBA attributes. Values are linear,
in [0, 1]. RGB supplies alpha 1. Vertex color multiplies the material's base color
and base-color map, while emission stays independent. Masked and blended materials
also multiply vertex alpha by map alpha and opacity; opaque materials ignore alpha.

For dynamic geometry, call `updateAttribute(VertexSemantic.color, values,
firstVertex: start)`. The values must match the original attribute format.
Triangle updates upload only affected GPU rows and preserve previously captured
views. Expanded lines and points upload their full recipe when edited.

See [vertex color usage and limits](../../docs/design/vertex-colors.md).
