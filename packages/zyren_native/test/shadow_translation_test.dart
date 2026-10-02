import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  for (final kind in ['point', 'spot', 'area']) {
    test(
      '$kind shadows survive camera translation and invalidate world edits',
      () async {
        final backend = await NativeBackend.create();
        try {
          for (final origin in [
            Vec3.zero,
            const Vec3(6378137.123, 9000000.456, -12000000.789),
          ]) {
            final scene = Scene()..background = const Color3(0, 0, 0);
            final root = scene.add(Group()..position = origin);
            root.add(
              Mesh(PlaneGeometry(width: 6, height: 6), StandardMaterial())
                ..receiveShadow = true,
            );
            final caster = root.add(
              Mesh(
                  BoxGeometry(width: .6, height: .6, depth: .6),
                  UnlitMaterial(),
                )
                ..position = const Vec3(0, 0, 1)
                ..castShadow = true,
            );
            final light = switch (kind) {
              'point' => PointLight(
                intensity: 8,
                shadow: PointShadow(normalBias: 0),
              ),
              'spot' => SpotLight(
                intensity: 8,
                shadow: SpotShadow(normalBias: 0),
              ),
              _ => RectAreaLight(
                width: 1,
                height: 1,
                intensity: 8,
                shadow: AreaShadow(resolution: 128, normalBias: 0),
              ),
            };
            root.add(light..position = const Vec3(-.75, 0, 2));
            final camera = PerspectiveCamera(
              position: origin + const Vec3(0, 0, 5),
              target: origin,
            );
            Future<ReadbackOutput> draw() async =>
                await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(31, 31),
                      ),
                    )
                    as ReadbackOutput;
            await draw();
            var before = await backend.shadowStats();
            for (final offset in [
              const Vec3(.017, .029, .037),
              const Vec3(.181, -.053, .107),
            ]) {
              camera.position = origin + const Vec3(0, 0, 5) + offset;
              final cached = await draw();
              final reused = await backend.shadowStats();
              expect(
                reused.renderedViews,
                before.renderedViews,
                reason: 'camera translation at $origin',
              );
              expect(reused.reusedFrames, greaterThan(before.reusedFrames));
              switch (light) {
                case PunctualLight():
                  light.invalidateShadow();
                case RectAreaLight():
                  light.invalidateShadow();
                default:
                  throw StateError('Unexpected fixture light');
              }
              final fresh = await draw();
              // Independent uncached rasterization at the same camera checks
              // that reusing depth did not move the visible shadow.
              var changed = 0;
              for (var i = 0; i < fresh.image.pixels.length; i++) {
                if ((cached.image.pixels[i] - fresh.image.pixels[i]).abs() >
                    2) {
                  changed++;
                }
              }
              expect(
                changed,
                lessThan(12),
                reason: 'cached and fresh shadow pixels',
              );
              before = await backend.shadowStats();
            }
            // Move camera and caster together so the camera-relative caster
            // matrix stays identical. The world edit must still invalidate.
            const step = Vec3(.001, 0, 0);
            camera.position = camera.position + step;
            caster.position = caster.position + step;
            await draw();
            var after = await backend.shadowStats();
            expect(after.renderedViews, greaterThan(before.renderedViews));
            before = after;
            light.position = light.position + step;
            await draw();
            after = await backend.shadowStats();
            expect(after.renderedViews, greaterThan(before.renderedViews));
            expect(after.residentBytes, 16 * 1024 * 1024);
            if (light case RectAreaLight()) {
              for (final edit in <void Function()>[
                () => light.width *= 1.5,
                () => light.height *= 1.5,
                () => light.rotateZ(.2),
                () => light.scale = const Vec3(2, 1, 1),
              ]) {
                before = after;
                edit();
                await draw();
                after = await backend.shadowStats();
                expect(
                  after.renderedViews,
                  greaterThan(before.renderedViews),
                  reason: 'area emitter shape moves shadow sample origins',
                );
              }
            }
            scene.clippingPlanes = [
              ClippingPlane(normal: const Vec3(1, 0, 0), offset: origin.x),
            ];
            await draw();
            before = await backend.shadowStats();
            camera.position = camera.position + step;
            await draw();
            after = await backend.shadowStats();
            expect(
              after.renderedViews,
              greaterThan(before.renderedViews),
              reason:
                  'camera-relative clipping retains conservative invalidation',
            );
          }
        } finally {
          await backend.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }
}
