import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:planet/navigation_failure_report.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';

import '../../../packages/zyren_3d_tiles/test/fixtures.dart';

void main() {
  test('missing tile streamer has no failures', () {
    expect(navigationTileFailures(null), isEmpty);
  });

  test(
    'serializes tile errors without dynamic enum lookup or provider data',
    () async {
      final manifest = AssetScope(
        services: AssetServices(
          resolver: MemoryResolver({
            '/tileset': tilesetBytes(tile(refine: 'REPLACE', uri: 'model')),
          }),
        ),
      );
      addTearDown(manifest.close);
      final tileset = await manifest
          .load(Tiles3D.tileset(Uri.parse('https://tiles.test/tileset')))
          .result;
      final resolver = MemoryResolver({})
        ..beforeRead = (_, _) async {
          throw AssetLoadException(
            AssetLoadError.sourceFailed,
            'private-provider-token',
            sourceUri: Uri.parse('https://tiles.test/private-provider-token'),
            httpStatus: 429,
          );
        };
      final streamer = Tiles3DStreamer(
        tileset: tileset,
        services: AssetServices(resolver: resolver),
      );
      addTearDown(streamer.dispose);
      streamer.update(
        PerspectiveCamera(
          position: const Vec3(0, -50, 0),
          up: const Vec3(0, 0, 1),
        ),
        const ViewportMetrics(800, 600),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (streamer.stats.activeRequests != 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(streamer.failures, hasLength(1));
      final report = navigationTileFailures(streamer.failures);
      expect(report, [
        {'code': 'sourceFailed', 'httpStatus': 429, 'attempts': 1},
      ]);
      expect(jsonEncode(report), isNot(contains('private-provider-token')));
      expect(jsonEncode(report), isNot(contains('tiles.test')));
    },
  );
}
