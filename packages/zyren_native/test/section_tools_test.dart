import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
// Package-local integration uses the optional tools plugin without a runtime dependency.
// ignore: depend_on_referenced_packages
import 'package:zyren_tools/zyren_tools.dart';

void main() {
  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy native caps expose solid interiors and clean up',
      () async {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final source = scene.add(
          Mesh(
            BoxGeometry(width: 2, height: 2, depth: 2),
            UnlitMaterial(
              color: const Color3(1, 0, 0),
              side: MaterialSide.front,
            ),
          ),
        );
        final sections = SceneSectionPlugin(
          capMaterial: UnlitMaterial(color: const Color3(0, 1, 0)),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: OrthographicCamera(
            depthStrategy: strategy,
            left: -1.5,
            right: 1.5,
            top: 1.5,
            bottom: -1.5,
            near: .1,
            far: 10,
            position: const Vec3(0, 0, 4),
          ),
          rendererFactory: NativeRenderer.create,
          plugins: [sections],
        );
        try {
          sections.setCapTargets([source]);
          sections.setPlanes([ClippingPlane(normal: const Vec3(0, 0, -1))]);
          final frame = await engine.render(
            width: 33,
            height: 33,
            elapsed: Duration.zero,
          );
          expect(
            frame.pixels.sublist((16 * 33 + 16) * 4, (16 * 33 + 16) * 4 + 4),
            [0, 255, 0, 255],
          );
          sections.clear();
          expect(source.children, isEmpty);
          final whole = await engine.render(
            width: 33,
            height: 33,
            elapsed: Duration.zero,
          );
          expect(
            whole.pixels.sublist((16 * 33 + 16) * 4, (16 * 33 + 16) * 4 + 4),
            [255, 0, 0, 255],
          );
        } finally {
          await engine.dispose();
        }
      },
      skip: !Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
    for (final overlay in [false, true]) {
      test(
        '$strategy native gizmo overlay=$overlay follows depth option',
        () async {
          final scene = Scene()..background = const Color3(0, 0, 0);
          final source = scene.add(
            Mesh(
              BoxGeometry(width: .2, height: .2, depth: .2),
              UnlitMaterial(),
            ),
          );
          scene.add(
            Mesh(
              BoxGeometry(width: 8, height: 8, depth: .2),
              UnlitMaterial(color: const Color3(0, 0, 1)),
            )..position = const Vec3(0, 0, 2),
          );
          final tools = SceneToolsPlugin(highlightSelection: false);
          final gizmo = TransformGizmoPlugin(alwaysVisible: overlay);
          final engine = await SceneEngine.create(
            scene: scene,
            camera: OrthographicCamera(
              depthStrategy: strategy,
              left: -3,
              right: 3,
              top: 3,
              bottom: -3,
              near: .1,
              far: 10,
              position: const Vec3(0, 0, 6),
            ),
            rendererFactory: NativeRenderer.create,
            plugins: [tools, gizmo],
          );
          try {
            tools.select(source);
            final frame = await engine.render(
              width: 101,
              height: 101,
              elapsed: Duration.zero,
            );
            final pixel = frame.pixels.sublist(
              (50 * 101 + 60) * 4,
              (50 * 101 + 60) * 4 + 4,
            );
            if (overlay) {
              expect(pixel[0], greaterThan(200));
            } else {
              expect(pixel, [0, 0, 255, 255]);
            }
          } finally {
            await engine.dispose();
          }
        },
        skip:
            !Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1',
      );
    }
  }
}
