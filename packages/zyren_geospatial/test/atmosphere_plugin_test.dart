import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'atmosphere plugin renders day, night, resizes and retires replaced tables',
    () async {
      final backend = await NativeBackend.create();
      final view = backend.createView();
      final camera = PerspectiveCamera(
        position: const Vec3(6379137, 0, 0),
        target: const Vec3(6379137, 0, 1000),
        up: const Vec3(1, 0, 0),
        near: 1,
        far: 1e8,
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(
          hdr: true,
          toneMapping: ToneMapping.aces,
        );
      final plugin = AtmospherePlugin(date: DateTime.utc(2026, 3, 20, 12));
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => view,
        plugins: [plugin],
      );
      try {
        Future<RenderedFrame> render(int w, int h) =>
            engine.render(elapsed: Duration.zero, width: w, height: h);
        final day = await render(64, 48);
        int light(RenderedFrame f) => f.pixels
            .whereIndexed((i, _) => i % 4 != 3)
            .fold(0, (a, b) => a + b);
        plugin.controller.date = DateTime.utc(2026, 3, 20);
        final night = await render(64, 48);
        expect(light(day), greaterThan(light(night) * 2));
        expect(
          day.pixels.whereIndexed((i, _) => i % 4 == 3),
          everyElement(255),
        );
        final bytes = (await backend.resourceStats()).residentBytes;
        for (var i = 0; i < 3; i++) {
          await render(31, 19);
          await render(64, 48);
        }
        expect((await backend.resourceStats()).residentBytes, bytes);
        final before = plugin.controller.parameters;
        final lighting = await plugin.controller.acquireLighting();
        expect(lighting.luts.parameters, same(before));
        await expectLater(
          plugin.controller.setParameters(
            before.copyWith(groundAlbedo: const Vec3(.2, .2, .2)),
            isCancelled: () => true,
          ),
          throwsStateError,
        );
        expect(plugin.controller.parameters, same(before));
        await render(64, 48);
        final pressure = GpuScope.fromBackend(backend);
        try {
          await pressure.resources.createBuffer(
            BufferDescriptor(
              size: 30 * 1024 * 1024,
              usage: {BufferUsage.storage},
            ),
          );
          final bytesWithPressure =
              (await backend.resourceStats()).residentBytes;
          await expectLater(
            plugin.controller.setParameters(
              before.copyWith(groundAlbedo: const Vec3(.4, .4, .4)),
            ),
            throwsA(isA<ResourceException>()),
          );
          expect(plugin.controller.parameters, same(before));
          expect(
            (await backend.resourceStats()).residentBytes,
            bytesWithPressure,
          );
          await render(64, 48);
        } finally {
          await pressure.close();
        }
        final zero = before.copyWith(
          rayleighScattering: Vec3.zero,
          mieScattering: Vec3.zero,
          mieExtinction: Vec3.zero,
          absorptionExtinction: Vec3.zero,
        );
        await plugin.controller.setParameters(zero);
        expect(plugin.controller.parameters, same(zero));
        expect(lighting.luts.isClosed, isFalse);
        await lighting.close();
        await render(64, 48);
        final pending = plugin.controller.setParameters(
          before.copyWith(groundAlbedo: const Vec3(.7, .7, .7)),
        );
        final rejected = expectLater(pending, throwsA(anything));
        await engine.dispose();
        await rejected;
        expect(plugin.controller.isClosed, isTrue);
        expect(
          () => plugin.controller.date = DateTime.utc(2026),
          throwsStateError,
        );
        expect(scene.effects, isEmpty);
        expect(scene.backgroundAlpha, scene.renderSettings.backgroundAlpha);
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 4)),
  );
}

extension<T> on Iterable<T> {
  Iterable<T> whereIndexed(bool Function(int, T) fn) sync* {
    var i = 0;
    for (final v in this) {
      if (fn(i++, v)) yield v;
    }
  }
}
