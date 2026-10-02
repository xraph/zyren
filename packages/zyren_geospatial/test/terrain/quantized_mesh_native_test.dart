import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'quantized_mesh_fixture.dart';
import 'terrain_extensions_test.dart' show withMetadata, range;

void main() {
  test(
    'HTTP terrain renders, retains parents on failure, retries and retires',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var failChildren = true;
      var requests = 0;
      var extensionHeader = false;
      final bytes = gridMeshFixture();
      server.listen((request) async {
        if (request.uri.path.endsWith('layer.json')) {
          request.response.write(
            jsonEncode({
              'maxzoom': 1,
              'metadataAvailability': 1,
              'extensions': ['metadata'],
              'attribution': 'Dynamic terrain fixture',
              'tiles': ['{z}/{x}/{y}.terrain'],
            }),
          );
        } else {
          requests++;
          extensionHeader =
              request.headers.value('accept') ==
              'application/vnd.quantized-mesh;extensions=metadata';
          if (failChildren && request.uri.path.startsWith('/1/')) {
            request.response.statusCode = 503;
          } else {
            final parts = request.uri.pathSegments;
            final x = int.parse(parts[1]);
            request.response.add(
              parts[0] == '0'
                  ? withMetadata(bytes, {
                      'available': [
                        [range(x * 2, 0, x * 2 + 1, 1)],
                      ],
                    })
                  : bytes,
            );
          }
        }
        await request.response.close();
      });
      final source = await QuantizedMeshTerrainSource.open(
        uri: Uri.parse('http://127.0.0.1:${server.port}/layer.json'),
        datasetId: 'native-fixture',
        resolver: const NativeSourceResolver(),
        cancellation: TestCancellation(),
        limits: QuantizedMeshLimits(
          maxVertices: 200,
          maxTriangles: 300,
          maxEdgeVertices: 60,
          maxEncodedBytes: 8192,
        ),
      );
      final backend = await NativeBackend.create();
      final terrain = TerrainPlugin(source: source, maximumScreenError: 1);
      final camera = PerspectiveCamera(
        position: const Vec3(80000000, 0, 0),
        target: Vec3.zero,
        up: const Vec3(0, 0, 1),
        near: .1,
        far: 1e9,
        depthStrategy: DepthStrategy.reversed,
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [GeospatialPlugin(), terrain],
      );
      try {
        Future<RenderedFrame> settle() async {
          var idleFrames = 0;
          for (var i = 0; i < 200; i++) {
            final frame = await engine.render(
              elapsed: Duration.zero,
              width: 256,
              height: 192,
            );
            idleFrames = terrain.stats!.activeRequests == 0
                ? idleFrames + 1
                : 0;
            if (idleFrames >= 2) return frame;
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          throw StateError('HTTP terrain did not settle.');
        }

        await settle();
        expect(terrain.visibleCoordinates.every((c) => c.z == 0), isTrue);
        expect(terrain.visibleCoordinates, isNotEmpty);
        camera.position = const Vec3(20000000, 0, 0);
        await settle();
        expect(terrain.failures, isNotEmpty);
        expect(terrain.visibleCoordinates.every((c) => c.z == 0), isTrue);
        failChildren = false;
        terrain.retryFailed();
        final detailed = await settle();
        expect(terrain.failures, isEmpty);
        expect(extensionHeader, isTrue);
        expect(terrain.attributions, ['Dynamic terrain fixture']);
        expect(terrain.visibleCoordinates.every((c) => c.z == 1), isTrue);
        var colored = 0;
        for (var i = 0; i < detailed.pixels.length; i += 4) {
          if (detailed.pixels[i] > 30 &&
              detailed.pixels[i + 1] > 30 &&
              detailed.pixels[i + 2] > 30) {
            colored++;
          }
        }
        expect(colored, greaterThan(4000));
        expect(
          terrain.stats!.residentBytes,
          lessThanOrEqualTo(terrain.budget.maxResidentBytes),
        );
        await engine.render(elapsed: Duration.zero, width: 130, height: 250);
        final replacement = await QuantizedMeshTerrainSource.open(
          uri: Uri.parse('http://127.0.0.1:${server.port}/layer.json'),
          datasetId: 'replacement',
          resolver: const NativeSourceResolver(),
          cancellation: TestCancellation(),
        );
        terrain.replaceSource(replacement);
        expect(terrain.visibleCoordinates, isEmpty);
        await settle();
        expect(terrain.visibleCoordinates, isNotEmpty);
        print(
          'Quantized HTTP native: $colored terrain pixels; $requests requests; ${terrain.visibleCoordinates.length} visible tiles.',
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
