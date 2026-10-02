import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import '../../../packages/zyren_gltf/test/support/fixtures.dart'
    show texturedModel;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native external tiles decode meshopt, Draco and Basis variants', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final runtime = android
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal();
    Future<Uint8List> asset(String path) async => (await rootBundle.load(
      'assets/qualification/$path',
    )).buffer.asUint8List();
    Uint8List jsonBytes(Object value) =>
        Uint8List.fromList(utf8.encode(jsonEncode(value)));
    Uint8List tileset(String content) => jsonBytes({
      'asset': {'version': '1.1'},
      'geometricError': 1000,
      'root': {
        'boundingVolume': {
          'sphere': [0, 0, 0, 10],
        },
        'geometricError': 0,
        'refine': 'REPLACE',
        'content': {'uri': content},
      },
    });
    final basisModel = texturedModel(
      minFilter: 9987,
      changes: {
        'extensionsUsed': ['KHR_materials_unlit', 'KHR_texture_basisu'],
        'extensionsRequired': ['KHR_materials_unlit', 'KHR_texture_basisu'],
        'images': [
          {'uri': 'colors.ktx2', 'mimeType': 'image/ktx2'},
        ],
        'textures': [
          {
            'sampler': 0,
            'extensions': {
              'KHR_texture_basisu': {'source': 0},
            },
          },
        ],
      },
    );
    final variants = <String, Map<String, Uint8List>>{
      'meshopt': {'model.glb': await asset('triangle.glb')},
      'Draco': {
        'model.gltf': await asset('khronos-box/Box.gltf'),
        'Box.bin': await asset('khronos-box/Box.bin'),
      },
      for (final format in ['etc1s', 'uastc', 'zstd'])
        'Basis $format': {
          'model.glb': basisModel,
          'colors.ktx2': await asset('colors-$format.ktx2'),
        },
    };
    for (final variant in variants.entries) {
      final files = variant.value;
      files['tileset.json'] = tileset('external.json');
      files['external.json'] = tileset(files.keys.first);
      final reads = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        reads.add(request.uri.path);
        final bytes = files[request.uri.path.substring(1)];
        if (bytes == null) {
          request.response.statusCode = 404;
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..add(HemisphereLight(intensity: 1));
      final controller = SceneController(
        scene: scene,
        camera: PerspectiveCamera(
          position: const Vec3(0, -3, 0),
          up: const Vec3(0, 0, 1),
        ),
        runtime: runtime,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
      );
      var frames = 0;
      final subscription = controller.frameStats.listen((frame) {
        expectSync(frame.readbackBytes, 0);
        frames++;
      });
      try {
        final tileset = await controller.assets
            .load(
              Tiles3D.tileset(
                Uri.parse('http://127.0.0.1:${server.port}/tileset.json'),
              ),
            )
            .result;
        final tiles = Tiles3DPlugin(
          tileset: tileset,
          services: runtime.assetServices,
        );
        controller.use(tiles);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SceneView(controller: controller)),
          ),
        );
        for (var attempt = 0; attempt < 500; attempt++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller.status.value case SceneFailed(:final issue)) {
            fail(
              '${variant.key}: ${issue.code}: ${issue.message}; ${issue.cause}',
            );
          }
          if (tiles.stats?.visibleTiles == 1 &&
              tiles.stats?.activeRequests == 0 &&
              frames > 2) {
            break;
          }
          controller.invalidate();
        }
        expect(tiles.failures, isEmpty);
        expect(tiles.stats?.visibleTiles, 1, reason: variant.key);
        expect(reads, contains('/external.json'));
        final before = frames;
        scene.background = const Color3(.002, 0, 0);
        controller.invalidate();
        for (var i = 0; i < 100 && frames <= before; i++) {
          controller.invalidate();
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(frames, greaterThan(before));
        final size = tester.getSize(find.byType(SceneView));
        final hit = await controller.pick(
          ViewportPoint(size.width / 2, size.height / 2),
        );
        expect(
          hit,
          isNotNull,
          reason: '${variant.key} must publish pickable geometry.',
        );
        expect(hit!.point.length, lessThan(2));
        expect(tiles.stats!.residentBytes, greaterThan(0));
        expect(tester.takeException(), isNull);
        debugPrint(
          '${variant.key}: $frames native frames, ${reads.length} HTTP reads, ${tiles.stats!.residentBytes} resident bytes.',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await controller.whenDisposed;
        await subscription.cancel();
        await server.close(force: true);
      }
      final diagnostics = await MethodChannel(
        android ? 'zyren/android-surfaces' : 'zyren/scene-views',
      ).invokeMapMethod<Object?, Object?>('diagnostics');
      for (final name in [
        'sessions',
        'renderers',
        'retiring',
        'readbackBytes',
        android ? 'surfaces' : 'heldDrawables',
      ]) {
        expect(diagnostics![name], 0, reason: '${variant.key}: $name');
      }
      debugPrint('${variant.key} cleanup: $diagnostics');
    }
  });
}
