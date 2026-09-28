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
