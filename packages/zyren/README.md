# Zyren

Build scenes, geometry and plugins in Dart without a Flutter engine or GPU.

```dart
import 'package:zyren/zyren.dart';

final scene = Scene()..add(Mesh(BoxGeometry(), DiffuseMaterial()));
final camera = PerspectiveCamera();
final snapshot = scene.snapshot(camera, 1);
```

You supply a `rendererFactory` when creating the core `SceneEngine`. Use
`zyren_native` for a native backend or `flutter_zyren` for Flutter views and the
native default. Geospatial remains an optional package.

Advanced output and backend contracts are in `package:zyren/rendering.dart`.
The renderer currently supports opaque meshes; the larger API design is still
being implemented. Run this package's tests with `fvm dart test` after resolving
the workspace dependencies.
