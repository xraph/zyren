import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'main.dart';
import 'experimental/native_scene_smoke.dart';

void main() {
  if (const bool.fromEnvironment('METAL_SCENE_SMOKE')) {
    runNativeSceneSmoke();
    return;
  }
  runApp(
    const MultipleViewsApp(
      runtime: SceneRuntime.nativeMetal(),
      presentation: PresentationPolicy.requireNative,
    ),
  );
}
