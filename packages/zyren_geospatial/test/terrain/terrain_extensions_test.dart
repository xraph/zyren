import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'quantized_mesh_fixture.dart';
import 'quantized_mesh_source_test.dart' show FixtureResolver, manifest;

Uint8List withExtension(Uint8List mesh, int id, List<int> data) =>
    Uint8List.fromList([
      ...mesh,
      id,
      ...(ByteData(
        4,
      )..setUint32(0, data.length, Endian.little)).buffer.asUint8List(),
      ...data,
    ]);
Uint8List withMetadata(Uint8List mesh, Object metadata) {
  final data = utf8.encode(jsonEncode(metadata));
  return withExtension(mesh, 4, [
    ...(ByteData(
      4,
    )..setUint32(0, data.length, Endian.little)).buffer.asUint8List(),
    ...data,
  ]);
}

Map<String, int> range(int x, int y, int ex, int ey) => {
  'startX': x,
  'startY': y,
  'endX': ex,
  'endY': ey,
};
Map<String, Object?> dynamicManifest() => manifest(maxzoom: 4)
  ..['extensions'] = ['octvertexnormals', 'watermask', 'metadata']
  ..['metadataAvailability'] = 2
  ..['attribution'] = 'Terrain fixture'
  ..['available'] = 'ignored when metadata is advertised';
Future<QuantizedMeshTerrainSource> openDynamic(
  FixtureResolver resolver, {
  int maxAvailabilityPages = 1024,
  int maxAvailabilityRanges = 16384,
}) => QuantizedMeshTerrainSource.open(
  uri: Uri.parse('https://terrain.test/layer.json'),
  datasetId: 'dynamic',
  resolver: resolver,
  cancellation: TestCancellation(),
  maxAvailabilityPages: maxAvailabilityPages,
  maxAvailabilityRanges: maxAvailabilityRanges,
);
Future<TerrainTile> load(
  QuantizedMeshTerrainSource source,
  TileCoordinate tile, {
  LoadCancellation? cancellation,
}) => source.load(
  tile,
  TileLoadContext(
    sourceIdentity: source.identity,
    cancellation: cancellation ?? TestCancellation(),
    byteBudget: source.describe(tile).decodedBytes,
  ),
);

void main() {
  test(
    'reloaded availability cannot replace a range with a duplicate',
    () async {
      final resolver = FixtureResolver(dynamicManifest());
      final source = await openDynamic(resolver);
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 0, 1), range(1, 0, 1, 1)],
        ],
      });
      await load(source, const TileCoordinate(0, 0, 0));
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 0, 1), range(0, 0, 0, 1)],
        ],
      });
      await expectLater(
        load(source, const TileCoordinate(0, 0, 0)),
        throwsA(isA<AssetLoadException>()),
      );
      expect(source.describe(const TileCoordinate(0, 0, 0)).children.length, 4);
    },
  );

  test(
    'metadata rejects truncation, duplicate keys, nesting and range limits',
    () {
      final mesh = meshFixture();
      final valid = withMetadata(mesh, {
        'available': [
          [range(0, 0, 1, 1)],
        ],
      });
      for (var length = mesh.length + 1; length < valid.length; length++) {
        expect(
          () => QuantizedMeshDecoder().decode(
            Uint8List.sublistView(valid, 0, length),
            rectangle: GeographicRectangle(0, 0, .1, .1),
            cancellation: TestCancellation(),
          ),
          throwsA(isA<AssetLoadException>()),
        );
      }
      for (final text in [
        '{"available":[],"available":[]}',
        '{"nested":${'[' * 17}0${']' * 17}}',
        '{"available":[[{"startX":0.5}]]}',
      ]) {
        final json = utf8.encode(text);
        final data = withExtension(mesh, 4, [
          ...(ByteData(
            4,
          )..setUint32(0, json.length, Endian.little)).buffer.asUint8List(),
          ...json,
        ]);
        expect(
          () => QuantizedMeshDecoder().decode(
            data,
            rectangle: GeographicRectangle(0, 0, .1, .1),
            cancellation: TestCancellation(),
          ),
          throwsA(isA<AssetLoadException>()),
        );
      }
      final two = withMetadata(mesh, {
        'available': [
          [range(0, 0, 0, 1), range(1, 0, 1, 1)],
        ],
      });
      expect(
        () =>
            QuantizedMeshDecoder(
              limits: QuantizedMeshLimits(maxMetadataRanges: 1),
            ).decode(
              two,
              rectangle: GeographicRectangle(0, 0, .1, .1),
              cancellation: TestCancellation(),
            ),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
    },
  );

  test(
    'water masks are immutable north-first bytes and metadata is bounded',
    () {
      final water = Uint8List(65536)
        ..[0] = 255
        ..[255] = 64
        ..[65280] = 128;
      final encoded = withMetadata(withExtension(meshFixture(), 2, water), {
        'available': [
          [range(0, 0, 1, 1)],
        ],
      });
      final tile = QuantizedMeshDecoder().decode(
        encoded,
        rectangle: GeographicRectangle(0, 0, .1, .1),
        cancellation: TestCancellation(),
      );
      expect(tile.waterMask!.size, 256);
      expect(tile.waterMask!.bytes[0], 255);
      expect(tile.waterMask!.bytes[255], 64);
      expect(tile.waterMask!.bytes[65280], 128);
      expect(() => tile.waterMask!.bytes[0] = 0, throwsUnsupportedError);
      expect(tile.availability!.levels.single.single.endX, 1);
      expect(() => tile.availability!.levels.clear(), throwsUnsupportedError);
      expect(
        tile.decodedBytes,
        lessThanOrEqualTo(QuantizedMeshLimits().decodedBytes),
      );
      for (final data in [
        <int>[],
        [0, 255],
        List<int>.filled(65535, 0),
      ]) {
        expect(
          () => QuantizedMeshDecoder().decode(
            withExtension(meshFixture(), 2, data),
            rectangle: GeographicRectangle(0, 0, .1, .1),
            cancellation: TestCancellation(),
          ),
          throwsA(isA<AssetLoadException>()),
        );
      }
      expect(
        () =>
            QuantizedMeshDecoder(
              limits: QuantizedMeshLimits(maxMetadataBytes: 16),
            ).decode(
              encoded,
              rectangle: GeographicRectangle(0, 0, .1, .1),
              cancellation: TestCancellation(),
            ),
        throwsA(isA<AssetLoadException>()),
      );
    },
  );

  test(
    'metadata unlocks relative levels, requests extensions and carries credits',
    () async {
      final resolver = FixtureResolver(dynamicManifest());
      final source = await openDynamic(resolver);
      const root = TileCoordinate(0, 0, 0),
          child = TileCoordinate(0, 0, 1),
          boundary = TileCoordinate(0, 0, 2),
          next = TileCoordinate(0, 0, 3);
      expect(source.availabilityOf(child), TerrainAvailability.unknown);
      expect(source.describe(root).children, isEmpty);
      resolver.tile = withMetadata(withExtension(meshFixture(), 2, [255]), {
        'available': [
          [range(0, 0, 1, 1)],
          [range(0, 0, 3, 3)],
        ],
      });
      final tile = await load(source, root);
      expect(tile.attributions, ['Terrain fixture']);
      expect(tile.waterMask!.bytes, [255]);
      expect(source.describe(root).children.length, 4);
      expect(source.describe(child).children.length, 4);
      expect(source.availabilityOf(boundary), TerrainAvailability.available);
      expect(source.availabilityOf(next), TerrainAvailability.unknown);
      expect(
        resolver.reads.last.queryParameters['extensions'],
        'octvertexnormals-watermask-metadata',
      );
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 1, 1)],
          [],
        ],
      });
      await load(source, boundary);
      expect(source.describe(boundary).children.length, 4);
      expect(
        source.availabilityOf(const TileCoordinate(0, 0, 4)),
        TerrainAvailability.unavailable,
      );
      expect(
        source.availabilityOf(const TileCoordinate(2, 0, 3)),
        TerrainAvailability.unknown,
      );
    },
  );

  test(
    'sparse pages retain coverage and rejected pages publish nothing',
    () async {
      final resolver = FixtureResolver(dynamicManifest());
      final source = await openDynamic(resolver);
      const root = TileCoordinate(0, 0, 0);
      for (final bytes in [
        meshFixture(),
        withMetadata(meshFixture(), {
          'available': [
            [range(0, 0, 2, 1)],
          ],
        }),
        withMetadata(meshFixture(), {
          'available': [
            [range(0, 0, 1, 1)],
            [],
            [],
          ],
        }),
        withMetadata(meshFixture(), {
          'available': [
            [range(0, 0, -1, 1)],
          ],
        }),
      ]) {
        resolver.tile = bytes;
        await expectLater(
          load(source, root),
          throwsA(isA<AssetLoadException>()),
        );
        expect(source.describe(root).children, isEmpty);
        expect(
          source.availabilityOf(const TileCoordinate(0, 0, 1)),
          TerrainAvailability.unknown,
        );
      }
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 1, 0)],
        ],
      });
      await load(source, root);
      expect(source.describe(root).children, isEmpty);
      expect(
        source.availabilityOf(const TileCoordinate(0, 1, 1)),
        TerrainAvailability.unavailable,
      );
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 1, 1)],
        ],
      });
      await expectLater(load(source, root), throwsA(isA<AssetLoadException>()));
      expect(source.describe(root).children, isEmpty);
    },
  );

  test(
    'cancellation retains physical work and does not publish late availability',
    () async {
      final resolver = FixtureResolver(dynamicManifest());
      final source = await openDynamic(resolver);
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 1, 1)],
        ],
      });
      final gate = Completer<void>();
      resolver.onRead = () => gate.future;
      final cancel = TestCancellation();
      var settled = false;
      final result = load(
        source,
        const TileCoordinate(0, 0, 0),
        cancellation: cancel,
      ).whenComplete(() => settled = true);
      final check = expectLater(result, throwsA(isA<LoadCancelled>()));
      cancel.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      gate.complete();
      await check;
      expect(source.describe(const TileCoordinate(0, 0, 0)).children, isEmpty);
      await load(source, const TileCoordinate(0, 0, 0));
      expect(source.describe(const TileCoordinate(0, 0, 0)).children.length, 4);
    },
  );

  test('retained pages and ranges have independent limits', () async {
    for (final pageLimit in [true, false]) {
      final resolver = FixtureResolver(dynamicManifest());
      final source = await openDynamic(
        resolver,
        maxAvailabilityPages: pageLimit ? 1 : 10,
        maxAvailabilityRanges: pageLimit ? 10 : 1,
      );
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(0, 0, 1, 1)],
        ],
      });
      await load(source, const TileCoordinate(0, 0, 0));
      resolver.tile = withMetadata(meshFixture(), {
        'available': [
          [range(2, 0, 3, 1)],
        ],
      });
      await expectLater(
        load(source, const TileCoordinate(1, 0, 0)),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      expect(source.describe(const TileCoordinate(1, 0, 0)).children, isEmpty);
    }
  });
}
