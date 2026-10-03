import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_capture/native_capture.dart';
import 'package:zyren_capture/src/tile_camera.dart';
import 'capture_test.dart' show FixtureBackend;

void main() {
  test('tile camera maps full-frame points into the cropped viewport', () {
    final camera = PerspectiveCamera(
      position: const Vec3(1, 2, 5),
      target: Vec3.zero,
    );
    final tile = TileCamera(
      camera,
      fullWidth: 100,
      fullHeight: 80,
      x: 25,
      y: 0,
      width: 50,
      height: 40,
    );
    final full = camera.projectPoint(Vec3.zero, 100 / 80),
        part = tile.projectPoint(Vec3.zero, 50 / 40);
    expect(part.x, closeTo(full.x * 2, 1e-12));
    expect(part.y, closeTo(full.y * 2 - 1, 1e-12));
    expect(part.z, closeTo(full.z, 1e-12));
  });
  test(
    'tiled cancellation removes only its incomplete output and rejects seam-prone effects',
    () async {
      final dir = await Directory.systemTemp.createTemp('zyren-tile-cancel-');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/keep').writeAsString('host data');
      late CaptureJob job;
      final backend = FixtureBackend(
        beforeReturn: () async {
          job.cancel();
        },
      );
      final manager = CaptureManager(
        scene: Scene(),
        sceneId: 'scene',
        documentId: 'doc',
        outputParent: dir,
        openBackend: () async => backend,
      );
      addTearDown(manager.close);
      job = manager.start(
        id: 'cancel',
        plan: CapturePlan(size: PhysicalSize(32, 32), tileDimension: 16),
      );
      await expectLater(job.done, throwsA(isA<CaptureCancelled>()));
      expect(backend.submissions.length, 1);
      expect(backend.closes, 1);
      expect(await dir.list().length, 1);
      manager.scene.renderSettings = RenderSettings(bloom: BloomSettings());
      final failed = manager.start(
        id: 'bloom',
        plan: CapturePlan(size: PhysicalSize(32, 32), tileDimension: 16),
      );
      await expectLater(failed.done, throwsUnsupportedError);
      expect(await dir.list().length, 1);
      expect(
        () => CapturePlan(size: PhysicalSize(8192, 8192), tileDimension: 512),
        throwsArgumentError,
      );
    },
  );
  test(
    'native tiled PNG matches full render and preserves transparent background',
    () async {
      final dir = await Directory.systemTemp.createTemp('zyren-tiles-native-');
      addTearDown(() => dir.delete(recursive: true));
      final scene = Scene()
        ..renderSettings = RenderSettings(backgroundAlpha: 0);
      scene.add(
        Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(.2, .4, .8))),
      );
      final manager = nativeCapture(
        scene: scene,
        sceneId: 'tile-test',
        documentId: 'fixture',
        outputParent: dir,
      );
      addTearDown(manager.close);
      final full = await manager
          .start(
            id: 'full',
            plan: CapturePlan(size: PhysicalSize(96, 80)),
          )
          .done;
      final tiled = await manager
          .start(
            id: 'tiled',
            plan: CapturePlan(size: PhysicalSize(96, 80), tileDimension: 32),
          )
          .done;
      expect(
        await File(tiled.frames.single).readAsBytes(),
        orderedEquals(await File(full.frames.single).readAsBytes()),
      );
      final manifest = jsonDecode(await File(tiled.manifest).readAsString());
      expect(manifest['frames'][0]['nativeFrameIds'].length, 9);
      // Decode the filter-0 rows written by our PNG encoder and inspect alpha.
      final png = await File(tiled.frames.single).readAsBytes();
      final payload = <int>[];
      for (var offset = 8; offset < png.length;) {
        final length =
            (png[offset] << 24) |
            (png[offset + 1] << 16) |
            (png[offset + 2] << 8) |
            png[offset + 3];
        final type = ascii.decode(png.sublist(offset + 4, offset + 8));
        if (type == 'IDAT') {
          payload.addAll(png.sublist(offset + 8, offset + 8 + length));
        }
        offset += length + 12;
      }
      final rows = zlib.decode(payload);
      final high = await manager
          .start(
            id: 'high',
            plan: CapturePlan(size: PhysicalSize(4097, 16), tileDimension: 512),
          )
          .done;
      expect(
        (jsonDecode(
                  await File(high.manifest).readAsString(),
                )['frames'][0]['nativeFrameIds']
                as List)
            .length,
        9,
      );
      expect(rows[4], 0);
      expect(rows[40 * (96 * 4 + 1) + 1 + 48 * 4 + 3], 255);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
