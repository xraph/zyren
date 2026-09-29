import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'HTTP imagery retains parent terrain on error, retries and releases Metal resources',
    () async {
      final png = await File(
        '../../test_assets/images/corners.png',
      ).readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var failChildren = true, requests = 0;
      server.listen((request) async {
        requests++;
        if (failChildren && request.uri.path.startsWith('/12/')) {
          request.response.statusCode = 503;
        } else {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(png);
        }
        await request.response.close();
      });
      final base = ProceduralTerrainSource(maximumLevel: 1, maximumHeight: 0);
      final imagery = TemplateImagerySource(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}/'),
        template: '{z}/{x}/{y}.png',
        datasetId: 'native-fixture',
        tileSize: 2,
        attribution: 'Fixture imagery',
        projection: ImageryProjection.geographic,
        services: AssetServices(
          resolver: const NativeSourceResolver(),
          imageDecoder: const NativeImageDecoder(),
        ),
      );
      final source = ImageryTerrainSource(
        terrain: base,
        outputSize: 64,
        layers: [ImageryLayer(imagery, levelOffset: 11)],
      );
      final terrain = TerrainPlugin(
        source: source,
        maximumScreenError: .000001,
      );
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: OrthographicCamera(
          position: const Vec3(6380137, 0, 0),
          target: const Vec3(6378137, 0, 0),
          up: const Vec3(0, 0, 1),
          left: -2000,
          right: 2000,
          top: 2000,
          bottom: -2000,
          near: 10,
          far: 5000,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [GeospatialPlugin(), terrain],
      );
      Future<RenderedFrame> render() =>
          engine.render(elapsed: Duration.zero, width: 128, height: 128);
      Future<RenderedFrame> settle() async {
        for (var i = 0; i < 300; i++) {
          await render();
          if (terrain.stats!.activeRequests == 0) return render();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('Imagery did not settle.');
      }

      try {
        await settle();
        expect(terrain.failures, isNotEmpty);
        expect(terrain.visibleCoordinates, {const TileCoordinate(0, 0, 0)});
        expect(terrain.attributions, ['Fixture imagery']);
        failChildren = false;
        terrain.retryFailed();
        final frame = await settle();
        expect(terrain.failures, isEmpty);
        expect(terrain.visibleCoordinates.length, 4);
        var colored = 0;
        for (var i = 0; i < frame.pixels.length; i += 4) {
          if (frame.pixels[i] > 30 || frame.pixels[i + 1] > 30) colored++;
        }
        expect(colored, greaterThan(5000));
        expect(
          terrain.stats!.residentBytes,
          lessThanOrEqualTo(terrain.budget.maxResidentBytes),
        );
        print(
          'Imagery Metal: $colored pixels; $requests HTTP image reads; parent fallback/retry passed.',
        );
      } finally {
        await engine.dispose();
        expect(scene.children, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
