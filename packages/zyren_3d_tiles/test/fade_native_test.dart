import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart' show ReadbackOutput;
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
// Share the synthetic HTTP dataset with the Flutter lab.
// ignore: avoid_relative_lib_imports
import '../../../examples/planet/lib/tiles3d_fixture.dart';

void main() {
  test(
    'stable HTTP replacement presents only complete non-stippled covers',
    () async {
      final fixture = await Tiles3DFixture.start(latency: Duration.zero);
      addTearDown(fixture.close);
      final services = AssetServices(
        resolver: const NativeSourceResolver(),
        imageDecoder: const NativeImageDecoder(),
      );
      final assets = AssetScope(services: services);
      addTearDown(assets.close);
      final tileset = await assets.load(Tiles3D.tileset(fixture.uri)).result;
      final tiles = Tiles3DPlugin(tileset: tileset, services: services);
      final backend = await NativeBackend.create();
      final view = backend.createView()..configureSceneUploadBudget(100);
      const origin = Vec3(6378137, 0, 0);
      final camera = PerspectiveCamera(
        position: origin + const Vec3(1500, -900, 900),
        target: origin,
        up: const Vec3(1, 0, 0),
        near: .1,
        far: 1e9,
        depthStrategy: DepthStrategy.reversed,
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      scene.add(
        DirectionalLight(direction: const Vec3(-1, .4, -.8), intensity: 3),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => view,
        plugins: [tiles],
      );
      try {
        Future<void> settle() async {
          for (var i = 0; i < 200; i++) {
            final frame = await engine.renderFrame(
              elapsed: Duration.zero,
              width: 256,
              height: 192,
            );
            if (tiles.stats!.activeRequests == 0 &&
                !tiles.isAwaitingPublication &&
                frame.stats.admission!.candidateReady) {
              await engine.renderFrame(
                elapsed: Duration.zero,
                width: 256,
                height: 192,
              );
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          fail('HTTP fixture did not settle');
        }

        await settle();
        expect(tiles.visibleTileIds, {'0'});
        fixture.failChildren = true;
        camera.position = origin + const Vec3(450, -450, 350);
        await settle();
        expect(tiles.failures, isNotEmpty);
        final parent = await engine.render(
          elapsed: Duration.zero,
          width: 256,
          height: 192,
        );
        fixture.failChildren = false;
        tiles.retryFailed();
        var staged = 0;
        final backlogs = <int>[];
        final images = <RenderedFrame>[];
        for (var i = 0; i < 200; i++) {
          final frame = await engine.renderFrame(
            elapsed: Duration(milliseconds: i * 16),
            width: 256,
            height: 192,
          );
          final image = (frame as ReadbackOutput).image;
          final pixels = RenderedFrame(
            image.pixels,
            image.size.width,
            image.size.height,
          );
          images.add(pixels);
          if (!frame.stats.admission!.candidateReady) {
            staged++;
            backlogs.add(frame.stats.admission!.uploadBacklogBytes);
            expect(tiles.visibleTileIds, {'0'});
            expect(
              pixels.pixels,
              orderedEquals(parent.pixels),
              reason: 'staging must present the intact parent, pixel for pixel',
            );
          }
          if (tiles.stats!.activeRequests == 0 &&
              frame.stats.admission!.candidateReady &&
              !tiles.visibleTileIds.contains('0')) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(staged, greaterThan(0));
        expect(tiles.visibleTileIds.length, greaterThan(1));
        expect(tiles.isTransitioning, isFalse);
        final detail = await engine.render(
          elapsed: const Duration(seconds: 4),
          width: 256,
          height: 192,
        );
        for (final frame in images) {
          bool equal(RenderedFrame a, RenderedFrame b) =>
              a.pixels.length == b.pixels.length &&
              Iterable<int>.generate(
                a.pixels.length,
              ).every((i) => a.pixels[i] == b.pixels[i]);
          expect(
            equal(frame, parent) || equal(frame, detail),
            isTrue,
            reason:
                'each image must be a complete cover, never a randomized mixture',
          );
        }
        expect(detail.pixels, isNot(orderedEquals(parent.pixels)));
        final capture = Platform.environment['ZYREN_TILE_CAPTURE_DIR'];
        if (capture != null) {
          final directory = Directory(capture)..createSync(recursive: true);
          File('${directory.path}/parent.rgba').writeAsBytesSync(parent.pixels);
          File('${directory.path}/detail.rgba').writeAsBytesSync(detail.pixels);
          File('${directory.path}/images.json').writeAsStringSync(
            jsonEncode({
              'width': 256,
              'height': 192,
              'format': 'rgba8',
              'stagedBacklogBytes': backlogs,
              'comparedFrames': images.length,
            }),
          );
        }
        print(
          'Stable Metal HTTP cover: $staged staged frames (backlog $backlogs), ${images.length} images equal to complete parent or detail; ${fixture.requests} requests.',
        );
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  for (final implicit in [false]) {
    test(
      'HTTP refinement fades retain parent coverage and release native resources',
      () async {
        final fixture = await Tiles3DFixture.start(
          latency: Duration.zero,
          implicitTiling: implicit,
        );
        addTearDown(fixture.close);
        final services = AssetServices(
          resolver: const NativeSourceResolver(),
          imageDecoder: const NativeImageDecoder(),
        );
        final assets = AssetScope(services: services);
        addTearDown(assets.close);
        final tileset = await assets.load(Tiles3D.tileset(fixture.uri)).result;
        final tiles = Tiles3DPlugin(
          tileset: tileset,
          services: services,
          fadeDuration: const Duration(milliseconds: 250),
        );
        final backend = await NativeBackend.create();
        const origin = Vec3(6378137, 0, 0);
        final camera = PerspectiveCamera(
          position: origin + const Vec3(1500, -900, 900),
          target: origin,
          up: const Vec3(1, 0, 0),
          near: .1,
          far: 1e9,
          depthStrategy: DepthStrategy.reversed,
        );
        final scene = Scene()..background = const Color3(0, 0, 0);
        final light = DirectionalLight(
          direction: const Vec3(-1, .4, -.8),
          intensity: 3,
        );
        scene.add(light);
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
          plugins: [tiles],
        );
        try {
          Future<RenderedFrame> settle() async {
            for (var i = 0; i < 200; i++) {
              await engine.render(
                elapsed: Duration.zero,
                width: 256,
                height: 192,
              );
              if (tiles.stats!.activeRequests == 0 &&
                  !tiles.isAwaitingPublication) {
                return engine.render(
                  elapsed: Duration.zero,
                  width: 256,
                  height: 192,
                );
              }
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            throw StateError('3D Tiles did not settle.');
          }

          await settle();
          expect(tiles.visibleTileIds, {'0'});
          fixture.failChildren = true;
          camera.position = origin + const Vec3(450, -450, 350);
          await settle();
          expect(tiles.visibleTileIds, {'0'});
          expect(tiles.failures, isNotEmpty);
          fixture.failChildren = false;
          tiles.retryFailed();
          await settle();
          expect(tiles.isTransitioning, isTrue);
          expect(tiles.visibleTileIds, contains('0'));
          await engine.render(elapsed: Duration.zero, width: 256, height: 192);
          final middle = await engine.renderFrame(
            elapsed: const Duration(milliseconds: 125),
            width: 256,
            height: 192,
          );
          expect(middle.stats.uploadedBytes, 0);
          expect(tiles.isTransitioning, isTrue);
          final frame = await engine.render(
            elapsed: const Duration(milliseconds: 250),
            width: 256,
            height: 192,
          );
          expect(tiles.isTransitioning, isFalse);
          expect(tiles.visibleTileIds.length, greaterThan(1));
          expect(tiles.visibleTileIds, isNot(contains('0')));
          var colored = 0;
          for (var i = 0; i < frame.pixels.length; i += 4) {
            if (frame.pixels[i] > 30 && frame.pixels[i + 1] > 30) colored++;
          }
          expect(colored, greaterThan(500));
          await engine.render(elapsed: Duration.zero, width: 130, height: 250);
          tiles.replaceTileset(tileset);
          expect(
            tiles.visibleTileIds,
            isNotEmpty,
          ); // Retained until the replacement publishes.
          await settle();
          print(
            '3D Tiles fade Metal: $colored pixels; ${tiles.visibleTileIds.length} detail tiles; ${fixture.requests} HTTP content requests.',
          );
        } finally {
          await engine.dispose();
          expect(scene.children, [light]);
          expect((await backend.resourceStats()).residentBytes, 0);
          await backend.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
