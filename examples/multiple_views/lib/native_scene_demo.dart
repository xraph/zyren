import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'main.dart';
import 'experimental/native_scene_smoke.dart';

void main() {
  if (const bool.fromEnvironment('METAL_SCENE_SMOKE')) {
    runNativeSceneSmoke();
    return;
  }
  runApp(
    MultipleViewsApp(
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
      presentation: PresentationPolicy.requireNative,
    ),
  );
}
