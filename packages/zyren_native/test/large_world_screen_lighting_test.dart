import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'scene_admission_test.dart' show largeGeometry;
import 'screen_lighting_test.dart' show sceneFixture, createBackend;

void main() {
  test(
    'screen effects match rebased pixels at large origins and retained motion',
    () async {
      final backend = await createBackend();
      final localView = backend.createView();
      final origin = const Vec3(6378137, -4194304, 2097152);
      final records = <Map<String, Object?>>[];
      final output = Platform.environment['TASK9_EVIDENCE'];
      Scene fixture(Vec3 offset, String effect, bool enabled) {
        final scene = sceneFixture();
        for (final mesh in scene.children.whereType<Mesh>()) {
          mesh.position += offset;
        }
        if (effect == 'ao') {
          scene.children.whereType<Mesh>().first.material = StandardMaterial(
            roughness: .8,
          );
          scene.add(HemisphereLight(groundColor: const Color3(1, 1, 1)));
        }
        scene.renderSettings = RenderSettings(
          screenSpaceLighting: enabled
              ? ScreenSpaceLighting(
                  ambientOcclusion: effect == 'ao',
                  reflections: effect == 'ssr',
                  quality: ScreenSpaceQuality.high,
                  radius: 2,
                  maxDistance: 8,
                )
              : ScreenSpaceLighting(),
        );
        return scene;
      }

      FrameSubmission capture(Scene scene, Vec3 offset, Vec3 motion) =>
          FrameSubmission.capture(
            scene: scene,
            camera: PerspectiveCamera(
              position: offset + motion,
              target: offset + const Vec3(0, 0, -1),
              fieldOfView: 1.1,
              near: .1,
              far: 30,
            ),
            size: PhysicalSize(96, 96),
          );
      void compare(String name, ReadbackOutput world, ReadbackOutput local) {
        var maxError = 0, changed = 0;
        for (var i = 0; i < world.image.pixels.length; i++) {
          final error = (world.image.pixels[i] - local.image.pixels[i]).abs();
          if (error > maxError) maxError = error;
          if (error != 0) changed++;
        }
        expect(maxError, 0, reason: name);
        records.add({
          'case': name,
          'maxByteError': maxError,
          'differentBytes': changed,
          'profile': world.stats.profile?.toJson(),
          'candidateReady': world.stats.admission?.candidateReady,
        });
        if (output != null) {
          File('$output/$name-world.rgba').writeAsBytesSync(world.image.pixels);
          File('$output/$name-local.rgba').writeAsBytesSync(local.image.pixels);
        }
      }

      try {
        for (final effect in ['ao', 'ssr']) {
          backend.configureSceneUploadBudget(64 * 1024 * 1024);
          final world = fixture(origin, effect, true),
              local = fixture(Vec3.zero, effect, true);
          final off =
              await localView.render(
                    capture(
                      fixture(Vec3.zero, effect, false),
                      Vec3.zero,
                      Vec3.zero,
                    ),
                  )
                  as ReadbackOutput;
          final initial =
              await backend.render(capture(world, origin, Vec3.zero))
                  as ReadbackOutput;
          final reference =
              await localView.render(capture(local, Vec3.zero, Vec3.zero))
                  as ReadbackOutput;
          expect(
            reference.image.pixels,
            isNot(off.image.pixels),
            reason: '$effect must change pixels',
          );
          compare('$effect-stationary', initial, reference);
          backend.configureSceneUploadBudget(64 * 1024);
          final candidate = fixture(origin, effect, true);
          for (var i = 0; i < 4; i++) {
            candidate.add(
              Mesh(largeGeometry(5000), UnlitMaterial())
                ..position = origin + Vec3(100.0 + i, 0, 0),
            );
          }
          for (final (index, motion) in [
            const Vec3(.125, .125, 0),
            const Vec3(-.125, -.125, 0),
          ].indexed) {
            final retained =
                await backend.render(capture(candidate, origin, motion))
                    as ReadbackOutput;
            expect(retained.stats.admission!.candidateReady, isFalse);
            final expected =
                await localView.render(capture(local, Vec3.zero, motion))
                    as ReadbackOutput;
            expect(retained.image.pixels, isNot(initial.image.pixels));
            compare('$effect-retained-$index', retained, expected);
          }
        }
        await localView.close();
        await backend.render(capture(Scene(), origin, Vec3.zero));
        final inspection = await backend.inspectGpu();
        expect(inspection.frameProfile!.screenLightingBytes, 0);
        final resources = await backend.resourceStats();
        expect(resources.residentBytes, 0);
        if (output != null) {
          File('$output/large-world-screen-lighting.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
              'origin': [origin.x, origin.y, origin.z],
              'size': [96, 96],
              'cases': records,
              'cleanupPayloadBytes': resources.residentBytes,
            }),
          );
        }
        print(
          'large-world screen effects: ${records.length} exact RGBA comparisons; cleanup ${resources.residentBytes} bytes',
        );
      } finally {
        await localView.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
