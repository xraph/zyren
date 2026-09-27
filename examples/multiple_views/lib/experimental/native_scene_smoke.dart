import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';

/// Standalone release check, selected by METAL_SCENE_SMOKE.
Future<void> runNativeSceneSmoke() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/scene-views');
  final scene = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
  final controllers = [
    SceneController(
      scene: scene,
      runtime: const SceneRuntime.nativeMetal(),
      options: const EngineOptions(renderMode: RenderMode.continuous),
    ),
    SceneController(
      scene: scene,
      camera: PerspectiveCamera(position: const Vec3(2, 1, 4)),
      runtime: const SceneRuntime.nativeMetal(),
      options: const EngineOptions(renderMode: RenderMode.continuous),
    ),
  ];
  final counts = [0, 0];
  var valid = true;
  final subscriptions = [
    for (var i = 0; i < controllers.length; i++)
      controllers[i].frameStats.listen((frame) {
        counts[i]++;
        valid &=
            frame.presentationPath == PresentationPath.nativeView &&
            frame.readbackBytes == 0;
      }),
  ];
  runApp(
    MaterialApp(
      home: Row(
        children: [
          for (final controller in controllers)
            Expanded(child: SceneView(controller: controller)),
        ],
      ),
    ),
  );
  try {
    await Future.wait(
      controllers.map((c) => c.firstFrame),
    ).timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(seconds: 8));
    final running = await channel.invokeMapMethod<Object?, Object?>(
      'diagnostics',
    );
    valid &=
        counts.every((count) => count > 10) &&
        (running?['presented'] as int) > 240 &&
        running?['renderers'] == 2 &&
        running?['readbackBytes'] == 0;
    for (final controller in controllers) {
      controller.dispose();
    }
    runApp(const SizedBox());
    await Future.wait(
      controllers.map((c) => c.whenDisposed),
    ).timeout(const Duration(seconds: 10));
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    final closed = await channel.invokeMapMethod<Object?, Object?>(
      'diagnostics',
    );
    valid &=
        closed?['renderers'] == 0 &&
        closed?['sessions'] == 0 &&
        closed?['retiring'] == 0 &&
        closed?['heldDrawables'] == 0;
    // The release smoke command checks this marker and the process exit status.
    // ignore: avoid_print
    print(
      'METAL_SCENE_SMOKE ${valid ? 'PASS' : 'FAIL'} samples=$counts running=$running closed=$closed',
    );
    exit(valid ? 0 : 1);
  } catch (error) {
    // ignore: avoid_print
    print('METAL_SCENE_SMOKE FAIL: $error');
    exit(1);
  }
}
