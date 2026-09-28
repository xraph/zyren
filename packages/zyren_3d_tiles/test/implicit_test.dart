import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart' show Geodetic;
import 'fixtures.dart';
import 'external_test.dart' show settle;

Uint8List jsonBytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Map<String, Object?> implicit({
  bool octree = false,
  int levels = 2,
  int subtreeLevels = 2,
  Map<String, Object>? bounds,
  List<double>? transform,
}) => {
  'boundingVolume':
      bounds ??
      {
        'box': [0, 0, 0, 8, 0, 0, 0, 8, 0, 0, 0, 8],
      },
  'geometricError': 16,
  'refine': 'REPLACE',
  'transform': ?transform,
  'content': {
    'uri': octree ? 'mesh/{level}/{x}/{y}/{z}.glb' : 'mesh/{level}/{x}/{y}.glb',
  },
  'implicitTiling': {
    'subdivisionScheme': octree ? 'OCTREE' : 'QUADTREE',
    'availableLevels': levels,
    'subtreeLevels': subtreeLevels,
    'subtrees': {
      'uri': octree
          ? 'sub/{level}/{x}/{y}/{z}.subtree'
          : 'sub/{level}/{x}/{y}.subtree',
    },
  },
};
Map<String, Object> availability({int content = 1}) => {
  'tileAvailability': {'constant': 1},
  'contentAvailability': [
    {'constant': content},
  ],
  'childSubtreeAvailability': {'constant': 0},
};
Uint8List binarySubtree(Object json, Uint8List data) {
  final text = jsonBytes(json), jsonLength = (text.length + 7) & ~7;
  final bytes = Uint8List(24 + jsonLength + ((data.length + 7) & ~7));
  final header = ByteData.sublistView(bytes);
  header.setUint32(0, 0x74627573, Endian.little);
  header.setUint32(4, 1, Endian.little);
  header.setUint64(8, jsonLength, Endian.little);
  header.setUint64(16, bytes.length - 24 - jsonLength, Endian.little);
  bytes.fillRange(24, 24 + jsonLength, 32);
  bytes.setRange(24, 24 + text.length, text);
  bytes.setRange(24 + jsonLength, 24 + jsonLength + data.length, data);
  return bytes;
}

const view = ViewportMetrics(800, 600);
OrthographicCamera camera({double size = 40, double x = 0}) =>
    OrthographicCamera(
      left: -size / 2,
      right: size / 2,
      top: size / 2,
      bottom: -size / 2,
      near: .1,
      far: 1e8,
      position: Vec3(x, -100, 0),
      target: Vec3(x, 0, 0),
      up: const Vec3(0, 0, 1),
    );
Future<Tiles3DStreamer> stream(
  MemoryResolver resolver, {
  Tiles3DLimits? limits,
}) async {
  final scope = AssetScope(services: AssetServices(resolver: resolver));
  final tileset = await scope
      .load(
        Tiles3D.tileset(Uri.parse('https://tiles.test/root'), limits: limits),
      )
      .result;
  await scope.close();
  final result = Tiles3DStreamer(
    tileset: tileset,
    services: AssetServices(resolver: resolver),
  );
  addTearDown(result.dispose);
  return result;
}

void main() {
  for (final octree in [false, true]) {
    test(
      '${octree ? 'octree' : 'quadtree'} constant availability resolves every child coordinate',
      () async {
        final resolver = MemoryResolver({
          '/root': tilesetBytes(
            implicit(
              octree: octree,
              transform: Mat4.compose(
                const Vec3(6378137, 0, 0),
                Quat.identity,
                Vec3.one,
              ).storage,
            ),
          ),
          '/sub/0/0/0${octree ? '/0' : ''}.subtree': jsonBytes(availability()),
          '/mesh/0/0/0${octree ? '/0' : ''}.glb': triangleModel(),
          for (var y = 0; y < 2; y++)
            for (var x = 0; x < 2; x++)
              for (var z = 0; z < (octree ? 2 : 1); z++)
                '/mesh/1/$x/$y${octree ? '/$z' : ''}.glb': triangleModel(),
        });
        final s = await stream(resolver);
        s.update(camera(x: 6378137), view);
        await settle(s);
        expect(s.failures, isEmpty);
        expect(s.visible, hasLength(octree ? 8 : 4));
        expect(resolver.reads.toSet(), resolver.files.keys.toSet());
        for (final group in s.visible.values) {
          expect(group.localMatrix.storage[12], closeTo(6378137, 1e-6));
        }
      },
    );
  }

  test(
    'child subtrees load lazily and preserve the parent across failure and retry',
    () async {
      final rootSubtree = availability()
        ..['childSubtreeAvailability'] = {'bitstream': 0, 'availableCount': 1};
      rootSubtree['buffers'] = [
        {'uri': 'bits.bin', 'byteLength': 1},
      ];
      rootSubtree['bufferViews'] = [
        {'buffer': 0, 'byteOffset': 0, 'byteLength': 1},
      ];
      final resolver = MemoryResolver({
        '/root': tilesetBytes(implicit(subtreeLevels: 1)),
        '/sub/0/0/0.subtree': jsonBytes(rootSubtree),
        '/sub/0/0/bits.bin': Uint8List.fromList([2]),
        '/mesh/0/0/0.glb': triangleModel(),
        '/mesh/1/1/0.glb': triangleModel(),
      });
      final s = await stream(resolver);
      s.update(camera(size: 2000), view);
      await settle(s);
      expect(s.failures, isEmpty);
      expect(s.visible, hasLength(1));
      expect(resolver.reads, isNot(contains('/sub/1/1/0.subtree')));
      final parent = s.visible.keys.single;
      s.update(camera(), view);
      await settle(s);
      expect(s.failures.single.code, AssetLoadError.sourceFailed);
      expect(s.visible.keys, [parent]);
      resolver.files['/sub/1/1/0.subtree'] = jsonBytes(availability());
      s.retryFailed();
      await settle(s);
      expect(s.failures, isEmpty);
      expect(s.visible, hasLength(1));
      expect(s.visible.keys, isNot(contains(parent)));
      expect(resolver.reads, contains('/mesh/1/1/0.glb'));
      expect(resolver.reads.where((p) => p.startsWith('/sub/2')), isEmpty);
    },
  );

  test(
    'binary availability uses breadth-first Morton ordering and skips absent content',
    () async {
      final bits = Uint8List(24)
        ..[0] = 0x13
        ..[8] = 0x12;
      final subtree = {
        'buffers': [
          {'byteLength': 24},
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 1},
          {'buffer': 0, 'byteOffset': 8, 'byteLength': 1},
        ],
        'tileAvailability': {'bitstream': 0, 'availableCount': 3},
        'contentAvailability': [
          {'bitstream': 1, 'availableCount': 2},
        ],
        'childSubtreeAvailability': {'constant': 0},
      };
      final resolver = MemoryResolver({
        '/root': tilesetBytes(implicit()),
        '/sub/0/0/0.subtree': binarySubtree(subtree, bits),
        '/mesh/1/0/0.glb': triangleModel(),
        '/mesh/1/1/1.glb': triangleModel(),
      });
      final s = await stream(resolver);
      s.update(camera(), view);
      await settle(s);
      expect(s.failures, isEmpty);
      expect(s.visible, hasLength(2));
      expect(resolver.reads.toSet(), resolver.files.keys.toSet());
    },
  );

  test(
    'deep Morton indices map octree coordinates and reject orphan tiles',
    () async {
      for (final orphan in [false, true]) {
        final bits = Uint8List(32);
        for (final bit in [0, if (!orphan) 6, 51]) {
          bits[bit ~/ 8] |= 1 << (bit % 8);
        }
        bits[16 + 51 ~/ 8] = 1 << (51 % 8);
        final subtree = {
          'buffers': [
            {'byteLength': 32},
          ],
          'bufferViews': [
            {'buffer': 0, 'byteOffset': 0, 'byteLength': 10},
            {'buffer': 0, 'byteOffset': 16, 'byteLength': 10},
          ],
          'tileAvailability': {'bitstream': 0},
          'contentAvailability': [
            {'bitstream': 1},
          ],
          'childSubtreeAvailability': {'constant': 0},
        };
        final resolver = MemoryResolver({
          '/root': tilesetBytes(
            implicit(octree: true, levels: 3, subtreeLevels: 3),
          ),
          '/sub/0/0/0/0.subtree': binarySubtree(subtree, bits),
          '/mesh/2/2/1/2.glb': triangleModel(),
        });
        final s = await stream(resolver);
        s.update(camera(), view);
        await settle(s);
        if (orphan) {
          expect(s.failures.single.code, AssetLoadError.invalidData);
          expect(s.visible, isEmpty);
          expect(resolver.reads, hasLength(2));
        } else {
          expect(s.failures, isEmpty);
          expect(s.visible, hasLength(1));
          expect(resolver.reads.last, '/mesh/2/2/1/2.glb');
        }
      }
    },
  );

  test(
    'invalid subtree bitstreams and lengths never publish geometry',
    () async {
      for (final kind in [
        'padding',
        'content-without-tile',
        'count',
        'range',
        'huge-header',
        'version',
        'child-past-levels',
        'metadata',
      ]) {
        final bits = Uint8List(16)
          ..[0] = 1
          ..[8] = 1;
        final data = <String, Object>{
          'buffers': [
            {'byteLength': 16},
          ],
          'bufferViews': [
            {'buffer': 0, 'byteOffset': 0, 'byteLength': 1},
            {'buffer': 0, 'byteOffset': 8, 'byteLength': 1},
          ],
          'tileAvailability': {'bitstream': 0},
          'contentAvailability': [
            {'bitstream': 1},
          ],
          'childSubtreeAvailability': {'constant': 0},
        };
        switch (kind) {
          case 'padding':
            bits[0] = 0x81;
          case 'content-without-tile':
            bits[8] = 3;
          case 'count':
            data['tileAvailability'] = {'bitstream': 0, 'availableCount': 2};
          case 'range':
            data['bufferViews'] = [
              {'buffer': 0, 'byteOffset': 16, 'byteLength': 1},
            ];
          case 'child-past-levels':
            data['childSubtreeAvailability'] = {'constant': 1};
          case 'metadata':
            data['tileMetadata'] = 0;
        }
        final bytes = binarySubtree(data, bits);
        if (kind == 'huge-header') {
          ByteData.sublistView(bytes).setUint32(12, 0x80000000, Endian.little);
        }
        if (kind == 'version') {
          ByteData.sublistView(bytes).setUint32(4, 2, Endian.little);
        }
        final resolver = MemoryResolver({
          '/root': tilesetBytes(implicit()),
          '/sub/0/0/0.subtree': bytes,
        });
        final s = await stream(resolver);
        s.update(camera(), view);
        await settle(s);
        expect(s.failures, hasLength(1), reason: kind);
        expect(s.visible, isEmpty, reason: kind);
        expect(resolver.reads, hasLength(2), reason: kind);
      }
    },
  );

  test(
    'subdivision halves errors and culls children in the transformed box',
    () async {
      final resolver = MemoryResolver({
        '/root': tilesetBytes(implicit(levels: 3, subtreeLevels: 3)),
        '/sub/0/0/0.subtree': jsonBytes(availability()),
        '/mesh/0/0/0.glb': triangleModel(),
        for (var y = 0; y < 2; y++)
          for (var x = 0; x < 2; x++) '/mesh/1/$x/$y.glb': triangleModel(),
      });
      final s = await stream(resolver);
      s.update(camera(size: 1000), view);
      await settle(s);
      expect(s.failures, isEmpty);
      expect(s.visible, hasLength(4));
      expect(resolver.reads.where((p) => p.startsWith('/mesh/2/')), isEmpty);
      final sparse = MemoryResolver({
        '/root': tilesetBytes(implicit()),
        '/sub/0/0/0.subtree': jsonBytes(availability()),
        '/mesh/0/0/0.glb': triangleModel(),
        '/mesh/1/1/0.glb': triangleModel(),
        '/mesh/1/1/1.glb': triangleModel(),
      });
      final c = await stream(sparse);
      c.update(camera(size: 1, x: 4), view);
      await settle(c);
      expect(c.failures, isEmpty);
      expect(c.visible, hasLength(2));
      expect(sparse.reads.where((p) => p.startsWith('/mesh/1/0')), isEmpty);
    },
  );

  test(
    'limits reject oversized subtrees and implicit structural violations',
    () async {
      for (final root in [
        implicit(subtreeLevels: 30),
        implicit(levels: 53),
        implicit()..['children'] = [],
        implicit()..['metadata'] = {},
        implicit()
          ..['boundingVolume'] = {
            'sphere': [0, 0, 0, 1],
          },
        implicit()..['content'] = {'uri': 'missing-template.glb'},
      ]) {
        await expectLater(
          stream(MemoryResolver({'/root': tilesetBytes(root)})),
          throwsA(isA<AssetLoadException>()),
        );
      }
      final resolver = MemoryResolver({
        '/root': tilesetBytes(implicit()),
        '/sub/0/0/0.subtree': jsonBytes(availability()),
      });
      final s = await stream(
        resolver,
        limits: Tiles3DLimits(maxSubtreeTiles: 4),
      );
      s.update(camera(), view);
      await settle(s);
      expect(s.failures.single.code, AssetLoadError.limitExceeded);
      expect(s.visible, isEmpty);
    },
  );

  test(
    'implicit content cannot recursively substitute an external tileset',
    () async {
      final resolver = MemoryResolver({
        '/root': tilesetBytes(implicit(levels: 1, subtreeLevels: 1)),
        '/sub/0/0/0.subtree': jsonBytes(availability()),
        '/mesh/0/0/0.glb': tilesetBytes(tile(refine: 'ADD', uri: 'other')),
      });
      final s = await stream(resolver);
      s.update(camera(), view);
      await settle(s);
      expect(s.failures.single.code, AssetLoadError.invalidData);
      expect(resolver.reads, hasLength(3));
    },
  );

  test(
    'octree regions cross the dateline and subdivide height without tile transforms',
    () async {
      final subtree = availability(content: 0);
      final resolver = MemoryResolver({
        '/root': tilesetBytes(
          implicit(
            octree: true,
            bounds: {
              'region': [math.pi - .02, -.01, -math.pi + .02, .01, 10, 110],
            },
            transform: Mat4.compose(
              const Vec3(1e9, 0, 0),
              Quat.identity,
              Vec3.one,
            ).storage,
          ),
        ),
        '/sub/0/0/0/0.subtree': jsonBytes(subtree),
      });
      final s = await stream(resolver);
      final eye = OrthographicCamera(
        left: -1e4,
        right: 1e4,
        bottom: -1e4,
        top: 1e4,
        near: 1,
        far: 1e8,
        position: const Vec3(-8e6, 0, 0),
        target: const Vec3(-6378137, 0, 0),
        up: const Vec3(0, 0, 1),
      );
      s.update(eye, view);
      await settle(s);
      expect(s.failures, isEmpty);
      final children = s.selected.values
          .where((n) => n.id.contains('/implicit/1/'))
          .toList();
      expect(children, hasLength(8));
      for (final node in children) {
        final xyz = node.id.split('/').skip(3).map(int.parse).toList();
        final lon = xyz[0] == 0 ? math.pi - .01 : -math.pi + .01;
        final lat = xyz[1] == 0 ? -.005 : .005;
        final expected = Geodetic(lon, lat).toEcef();
        expect((node.bounds.center - expected).length, lessThan(1e-6));
        expect(node.geometricError, 8);
        final other = children.singleWhere(
          (n) =>
              n.id ==
              '${node.id.substring(0, node.id.length - 1)}${1 - xyz[2]}',
        );
        expect(
          node.bounds.radius - other.bounds.radius,
          closeTo(xyz[2] == 1 ? 50 : -50, 1e-7),
        );
      }
      expect(() => s.selected.clear(), throwsUnsupportedError);
    },
  );

  test(
    'redirected subtree buffers use their effective URL while content uses the tileset URL',
    () async {
      final data = availability()
        ..['buffers'] = [
          {'uri': 'bits.bin', 'byteLength': 1},
        ]
        ..['bufferViews'] = [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 1},
        ]
        ..['contentAvailability'] = [
          {'bitstream': 0},
        ];
      final resolver = RedirectSubtreeResolver({
        '/root': tilesetBytes(implicit()),
        '/relocated/subtree': jsonBytes(data),
        '/relocated/bits.bin': Uint8List.fromList([0x1e]),
        for (var y = 0; y < 2; y++)
          for (var x = 0; x < 2; x++) '/mesh/1/$x/$y.glb': triangleModel(),
      });
      final s = await stream(resolver);
      s.update(camera(), view);
      await settle(s);
      expect(s.failures, isEmpty);
      expect(s.visible, hasLength(4));
      expect(resolver.reads.toSet(), resolver.files.keys.toSet());
    },
  );

  test(
    'subtree buffers obey origin policy and cancellation owns physical reads',
    () async {
      final gate = Completer<void>();
      final subtree = availability()
        ..['buffers'] = [
          {'uri': 'bits.bin', 'byteLength': 1},
        ];
      final resolver =
          MemoryResolver({
              '/root': tilesetBytes(implicit()),
              '/sub/0/0/0.subtree': jsonBytes(subtree),
              '/sub/0/0/bits.bin': Uint8List(1),
            })
            ..beforeRead = (uri, _) async {
              if (uri.path.endsWith('bits.bin')) await gate.future;
            };
      final s = await stream(resolver);
      s.update(camera(), view);
      for (
        var i = 0;
        i < 100 && !resolver.reads.last.endsWith('bits.bin');
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(resolver.reads.last, endsWith('bits.bin'));
      var closed = false;
      final closing = s.dispose().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closed, isFalse);
      gate.complete();
      await closing;
      expect(s.visible, isEmpty);

      subtree['buffers'] = [
        {'uri': 'https://another.test/bits.bin', 'byteLength': 1},
      ];
      resolver.files['/sub/0/0/0.subtree'] = jsonBytes(subtree);
      final next = await stream(resolver);
      next.update(camera(), view);
      await settle(next);
      expect(next.failures.single.code, AssetLoadError.forbiddenReference);
    },
  );
}

class RedirectSubtreeResolver extends MemoryResolver {
  RedirectSubtreeResolver(super.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) => super.read(
    uri.path.startsWith('/sub/') ? uri.resolve('/relocated/subtree') : uri,
    context,
  );
}
