import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:shader_lab/shader_lab.dart';

void main() {
  test(
    'public renderer consumer lights instances, shares views and drains owners',
    () async {
      final backend = await NativeBackend.create(),
          second = backend.createView();
      final fixture = RendererFixture();
      final engine = await SceneEngine.create(
        scene: fixture.scene,
        camera: fixture.camera,
        backendFactory: () async => backend,
        plugins: [
          RendererProfilePlugin(),
          fixture.environment(),
          ShaderLabPlugin(),
        ],
      );
      try {
        final first = await engine.render(
          elapsed: Duration.zero,
          width: 160,
          height: 120,
        );
        expect(
          first.pixels.where((v) => v > 50 && v < 250).length,
          greaterThan(1000),
        );
        final stats = await backend.graphStats();
        expect(stats.instanceBytes, 64 * 112);
        expect(stats.shadowPasses, 3);
        expect(stats.shadowBytes, greaterThan(0));
        expect(stats.targetBytes, greaterThan(160 * 120 * 84));
        final other = await SceneEngine.create(
          scene: fixture.scene,
          camera: fixture.camera,
          backendFactory: () async => second,
        );
        try {
          final copied = await other.render(
            elapsed: Duration.zero,
            width: 160,
            height: 120,
          );
          expect(copied.pixels, first.pixels);
          fixture.instances.setTransform(
            0,
            Mat4.compose(
              const Vec3(0, 1, 1),
              Quat.identity,
              const Vec3(.4, .4, .4),
            ),
          );
          expect(
            (await engine.render(
              elapsed: const Duration(seconds: 1),
              width: 240,
              height: 160,
            )).pixels,
            isNotEmpty,
          );
          expect(
            (await other.render(
              elapsed: const Duration(seconds: 1),
              width: 120,
              height: 120,
            )).pixels,
            isNotEmpty,
          );
        } finally {
          await other.dispose();
        }
        // Release effects and environment while retaining a diagnostic device owner.
        final observer = backend.createView();
        await engine.dispose();
        expect((await observer.graphStats()).targetBytes, 0);
        expect((await observer.graphStats()).shadowBytes, 0);
        expect((await observer.graphStats()).instanceBytes, 0);
        expect((await observer.resourceStats()).residentBytes, 0);
        await observer.close();
      } finally {
        await engine.dispose();
        await second.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
