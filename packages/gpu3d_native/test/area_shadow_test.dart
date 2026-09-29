import 'dart:io';
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

double linear(int x) {
  final v = x / 255;
  return v <= .04045 ? v / 12.92 : math.pow((v + .055) / 1.055, 2.4).toDouble();
}

void main() {
  test(
    'area shadows occlude emitter patches and reuse bounded atlas storage',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final receiver = scene.add(
          Mesh(
            PlaneGeometry(width: 10, height: 10),
            PhysicalMaterial(specularIntensity: 0),
          )..receiveShadow = true,
        );
        final blocker = scene.add(
          Mesh(
              PlaneGeometry(width: 1.5, height: 1.5),
              UnlitMaterial(color: const Color3(0, 0, 0)),
            )
            ..position = const Vec3(0, 0, 1.5)
            ..castShadow = true,
        );
        final light = scene.add(
          RectAreaLight(width: 2, height: 2, intensity: 3)
            ..position = const Vec3(0, 0, 3),
        );
        final camera = PerspectiveCamera(position: const Vec3(4, 0, 3));
        Future<int> draw() async =>
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(63, 63),
                      ),
                    )
                    as ReadbackOutput)
                .image
                .pixels[(31 * 63 + 31) * 4];
        final lit = await draw();
        expect(lit, greaterThan(50));
        light.shadow = AreaShadow(
          resolution: 256,
          normalBias: .001,
          filterRadius: 0,
        );
        expect(await draw(), lessThan(5));
        final before = await backend.shadowStats();
        await draw();
        final reused = await backend.shadowStats();
        expect(reused.renderedViews, before.renderedViews);
        expect(reused.reusedFrames, greaterThan(before.reusedFrames));
        blocker.position = const Vec3(.75, 0, 1.5);
        final partial = await draw();
        expect(linear(partial) / linear(lit), closeTo(.5, .06));
        light.position = const Vec3(4, 0, 3);
        final moved = await draw();
        expect(moved, greaterThan(10));
        light.position = const Vec3(0, 0, 3);
        receiver.receiveShadow = false;
        expect(await draw(), closeTo(lit, 2));
        receiver.receiveShadow = true;
        blocker.castShadow = false;
        expect(await draw(), closeTo(lit, 2));
        blocker.castShadow = true;
        light.shadow = light.shadow!.copyWith(strength: 0);
        expect(await draw(), closeTo(lit, 2));
        light.shadow = AreaShadow();
        for (var i = 0; i < 3; i++) {
          scene.add(
            RectAreaLight(width: 2, height: 2, shadow: AreaShadow())
              ..position = const Vec3(4, 0, 3),
          );
        }
        scene.add(
          DirectionalLight(
            intensity: 0,
            shadow: DirectionalShadow(cascades: 1, resolution: 128),
          ),
        );
        final viewsBefore = (await backend.shadowStats()).renderedViews;
        await draw();
        expect((await backend.shadowStats()).renderedViews - viewsBefore, 97);
        expect((await backend.shadowStats()).residentBytes, 16 * 1024 * 1024);
        for (final node in scene.children.toList()) {
          if (node is RectAreaLight) node.shadow = null;
          if (node is DirectionalLight) node.shadow = null;
        }
        await draw();
        expect((await backend.shadowStats()).residentBytes, 0);
      } on SceneException catch (e) {
        fail(e.issue.cause.toString());
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
