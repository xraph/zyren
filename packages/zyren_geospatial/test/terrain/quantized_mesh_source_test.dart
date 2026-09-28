import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'quantized_mesh_fixture.dart';

Map<String, Object?> manifest({int maxzoom = 2}) => {
  'format': 'quantized-mesh-1.0',
  'version': 'fixture-1',
  'maxzoom': maxzoom,
  'tiles': ['{z}/{x}/{y}.terrain?v={version}'],
  'extensions': ['octvertexnormals'],
};
TileLoadContext contextFor(
  QuantizedMeshTerrainSource source, {
  LoadCancellation? cancellation,
  int? bytes,
}) => TileLoadContext(
  sourceIdentity: source.identity,
  cancellation: cancellation ?? TestCancellation(),
  byteBudget: bytes ?? source.limits.decodedBytes,
);

class FixtureResolver implements ByteSourceResolver {
  Map<String, Object?> layer;
  Uint8List tile = meshFixture(normals: true);
  final reads = <Uri>[];
  Future<void> Function()? onRead;
  Uri? effectiveUri;
  FixtureResolver([Map<String, Object?>? layer]) : layer = layer ?? manifest();
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads.add(uri);
    await onRead?.call();
    return ResolvedSource(
      effectiveUri: effectiveUri ?? uri,
      bytes: uri.path.endsWith('layer.json')
          ? Uint8List.fromList(utf8.encode(jsonEncode(layer)))
          : tile,
    );
  }
}

Future<QuantizedMeshTerrainSource> openFixture(
  FixtureResolver resolver, {
  LoadCancellation? cancellation,
}) => QuantizedMeshTerrainSource.open(
  uri: Uri.parse('https://terrain.test/layer.json?token=private'),
  datasetId: 'fixture',
  resolver: resolver,
  cancellation: cancellation ?? TestCancellation(),
);

void main() {
  test(
    'opens metadata, resolves templates and requests advertised oct normals',
    () async {
      final resolver = FixtureResolver();
      final source = await openFixture(resolver);
      expect(source.roots.toList(), [
        const TileCoordinate(0, 0, 0),
        const TileCoordinate(1, 0, 0),
      ]);
      expect(source.version, 'fixture-1');
      expect(source.identity, contains('fixture-1'));
      expect(source.identity, isNot(contains('private')));
      const coord = TileCoordinate(2, 1, 2);
      final meta = source.describe(coord);
      final tile = await source.load(coord, contextFor(source));
      expect(resolver.reads.last.path, '/2/2/1.terrain');
      expect(resolver.reads.last.queryParameters, {
        'v': 'fixture-1',
        'extensions': 'octvertexnormals',
      });
      expect(tile.decodedBytes, lessThanOrEqualTo(meta.decodedBytes));
      expect(tile.residentBytes, lessThanOrEqualTo(meta.residentBytes));
      for (var i = 0; i < tile.geometry.positions.length; i += 3) {
        expect(
          (tile.origin + Vec3.array(tile.geometry.positions, i) - meta.center)
              .length,
          lessThanOrEqualTo(meta.radius),
        );
      }
    },
  );

  test(
    'sparse availability keeps the parent; complete sibling sets refine',
    () async {
      final layer = manifest()
        ..['available'] = [
          [
            {'startX': 0, 'startY': 0, 'endX': 1, 'endY': 0},
          ],
          [
            {'startX': 0, 'startY': 0, 'endX': 1, 'endY': 0},
          ],
          [],
        ];
      var source = await openFixture(FixtureResolver(layer));
      expect(source.describe(const TileCoordinate(0, 0, 0)).children, isEmpty);
      expect(
        () => source.describe(const TileCoordinate(0, 1, 1)),
        throwsRangeError,
      );
      (layer['available'] as List)[1] = [
        {'startX': 0, 'startY': 0, 'endX': 1, 'endY': 1},
      ];
      source = await openFixture(FixtureResolver(layer));
      expect(source.describe(const TileCoordinate(0, 0, 0)).children.length, 4);
      expect(source.describe(const TileCoordinate(1, 0, 0)).children, isEmpty);
    },
  );

  test('rejects unsupported manifest modes before tile reads', () async {
    for (final entry in {
      'projection': 'EPSG:3857',
      'scheme': 'slippyMap',
      'parentUrl': 'parent/layer.json',
      'metadataAvailability': 10,
      'minzoom': 1,
      'format': 'heightmap-1.0',
    }.entries) {
      final resolver = FixtureResolver(manifest()..[entry.key] = entry.value);
      await expectLater(
        openFixture(resolver),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.unsupportedFeature,
          ),
        ),
      );
      expect(resolver.reads.length, 1);
    }
  });

  test('rejects malformed manifests and hostile URL templates', () async {
    for (final entry in <String, Object?>{
      'maxzoom': 31,
      'tiles': ['https://other.test/{z}/{x}/{y}'],
      'available': [
        [
          {'startX': 0, 'startY': 0, 'endX': 1000000, 'endY': 1},
        ],
      ],
      'version': 'bad{version}',
    }.entries) {
      await expectLater(
        openFixture(FixtureResolver(manifest()..[entry.key] = entry.value)),
        throwsA(isA<AssetLoadException>()),
      );
    }
  });

  test(
    'validates effective URIs and caps bytes even with an uncooperative resolver',
    () async {
      final resolver = FixtureResolver();
      final source = await openFixture(resolver);
      resolver.effectiveUri = Uri.parse('https://other.test/secret');
      await expectLater(
        source.load(const TileCoordinate(0, 0, 0), contextFor(source)),
        throwsA(isA<AssetLoadException>()),
      );
      resolver.effectiveUri = null;
      resolver.tile = Uint8List(source.limits.maxEncodedBytes + 1);
      await expectLater(
        source.load(const TileCoordinate(0, 0, 0), contextFor(source)),
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
    'rejects budget and identity before reading and cancellation after await',
    () async {
      final resolver = FixtureResolver();
      final source = await openFixture(resolver);
      await expectLater(
        source.load(
          const TileCoordinate(0, 0, 0),
          contextFor(source, bytes: 1),
        ),
        throwsArgumentError,
      );
      await expectLater(
        source.load(
          const TileCoordinate(0, 0, 0),
          TileLoadContext(
            sourceIdentity: 'other',
            cancellation: TestCancellation(),
            byteBudget: source.limits.decodedBytes,
          ),
        ),
        throwsArgumentError,
      );
      expect(resolver.reads.length, 1);
      final cancel = TestCancellation();
      resolver.onRead = () async {
        cancel.cancel();
      };
      await expectLater(
        source.load(
          const TileCoordinate(0, 0, 0),
          contextFor(source, cancellation: cancel),
        ),
        throwsA(isA<LoadCancelled>()),
      );
    },
  );

  test(
    'native HTTP handles gzip, failures, explicit retry and cancellation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var fail = true, hang = false;
      final arrived = Completer<void>();
      server.listen((request) async {
        if (request.uri.path.endsWith('layer.json')) {
          request.response.write(jsonEncode(manifest(maxzoom: 0)));
        } else if (hang) {
          arrived.complete();
          return;
        } else if (fail) {
          request.response.statusCode = 503;
        } else {
          request.response.headers.set(
            HttpHeaders.contentEncodingHeader,
            'gzip',
          );
          request.response.add(gzip.encode(meshFixture()));
        }
        await request.response.close();
      });
      final source = await QuantizedMeshTerrainSource.open(
        uri: Uri.parse(
          'http://127.0.0.1:${server.port}/layer.json?token=private',
        ),
        datasetId: 'http-fixture',
        resolver: const NativeSourceResolver(),
        cancellation: TestCancellation(),
      );
      try {
        await source.load(const TileCoordinate(0, 0, 0), contextFor(source));
        failTest('HTTP failure must surface');
      } on AssetLoadException catch (error) {
        expect(error.toString(), isNot(contains('private')));
        expect(error.code, AssetLoadError.sourceFailed);
      }
      fail = false;
      expect(
        (await source.load(
          const TileCoordinate(0, 0, 0),
          contextFor(source),
        )).geometry.indices,
        isNotEmpty,
      );
      hang = true;
      final cancel = TestCancellation();
      final pending = expectLater(
        source.load(
          const TileCoordinate(0, 0, 0),
          contextFor(source, cancellation: cancel),
        ),
        throwsA(isA<LoadCancelled>()),
      );
      await arrived.future;
      cancel.cancel();
      await pending.timeout(const Duration(seconds: 2));
    },
  );
}

Never failTest(String message) => throw TestFailure(message);
