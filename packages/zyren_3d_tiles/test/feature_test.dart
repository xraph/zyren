import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import '../../zyren_gltf/test/features_test.dart' show featureModel;
import '../../zyren_gltf/test/metadata_test.dart' show metadataFeatureModel;
import 'fixtures.dart' show MemoryResolver, tile;
import 'streaming_test.dart' show source, settle;

List<Mesh> featureMeshes(Object3D root) => [
  if (root is Mesh) root,
  for (final child in root.children) ...featureMeshes(child),
];

Uint8List batchModel({
  String? copyright,
  Map<String, Object?>? properties,
  int count = 2,
  Uint8List? batchBinary,
}) {
  final model = featureModel(
    legacy: true,
    changes: {
      if (copyright != null)
        'asset': {'version': '2.0', 'copyright': copyright},
    },
  );
  List<int> paddedJson(Object value, int start) {
    final bytes = utf8.encode(jsonEncode(value));
    return [...bytes, ...List.filled((8 - (start + bytes.length) % 8) % 8, 32)];
  }

  final feature = paddedJson({'BATCH_LENGTH': count}, 28);
  final batch = paddedJson(
    properties ??
        {
          'name': ['North', 'South'],
          'height': [12, 40],
        },
    0,
  );
  final bin = batchBinary ?? Uint8List(0);
  final paddedBin = [...bin, ...List.filled((8 - bin.length % 8) % 8, 0)];
  final start = 28 + feature.length + batch.length + paddedBin.length;
  final bytes = Uint8List((start + model.length + 7) & ~7);
  final header = ByteData.sublistView(bytes);
  for (final (at, value) in [
    (0, 0x6d643362),
    (4, 1),
    (8, bytes.length),
    (12, feature.length),
    (20, batch.length),
    (24, paddedBin.length),
  ]) {
    header.setUint32(at, value, Endian.little);
  }
  bytes.setRange(28, 28 + feature.length, feature);
  bytes.setRange(
    28 + feature.length,
    28 + feature.length + batch.length,
    batch,
  );
  bytes.setRange(start - paddedBin.length, start, paddedBin);
  bytes.setRange(start, start + model.length, model);
  return bytes;
}

class FeatureSource implements ByteSourceResolver {
  final Uint8List bytes;
  FeatureSource(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

Future<TileModel3D> loadFeature(Uint8List bytes) {
  final scope = AssetScope(
    services: AssetServices(resolver: FeatureSource(bytes)),
  );
  addTearDown(scope.close);
  return scope
      .load(Tiles3D.content(Uri.parse('asset:///features.b3dm')))
      .result;
}

void main() {
  test('modern property tables drive the same feature style API', () async {
    final instance = (await loadFeature(metadataFeatureModel())).instantiate();
    expect(instance.features.last.properties['height'], 40);
    instance.setStyle(
      TileStyle3D(
        (f) => TileFeatureStyle3D(show: (f.properties['height'] as num) > 20),
      ),
    );
    expect(featureMeshes(instance).map((m) => m.visible), [false, true]);
  });
  test(
    'styles preserve authored resources, picking and sibling instances',
    () async {
      final model = await loadFeature(batchModel());
      final instance = model.instantiate(), sibling = model.instantiate();
      final meshes = featureMeshes(instance), original = meshes.first.material;
      final geometry = meshes.first.geometry;
      final scene = Scene()..add(instance);
      final ray = CameraRay(const Vec3(-1, -3, 0), const Vec3(0, 1, 0));
      final hit = Raycaster().intersectScene(scene, ray).single;
      expect(instance.featureFor(hit)!.properties['name'], 'North');
      var calls = 0;
      instance.setStyle(
        TileStyle3D((feature) {
          calls++;
          return TileFeatureStyle3D(
            show: feature.id != 0,
            color: const Color3(0, 0, 1),
            opacity: .5,
          );
        }),
      );
      expect(calls, 2);
      expect(Raycaster().intersectScene(scene, ray), isEmpty);
      expect(meshes.first.geometry, same(geometry));
      expect(meshes.last.material.alphaMode, MaterialAlphaMode.blend);
      expect(meshes.last.material.opacity, .5);
      expect(featureMeshes(sibling).first.material, same(original));
      expect(featureMeshes(sibling).first.visible, isTrue);
      final styled = meshes.last.material;
      expect(
        () => instance.setStyle(
          TileStyle3D((feature) {
            if (feature.id == 1) throw StateError('Style failed');
            return TileFeatureStyle3D(color: const Color3(1, 0, 0));
          }),
        ),
        throwsStateError,
      );
      expect(meshes.last.material, same(styled));
      expect(meshes.first.visible, isFalse);
      instance.setStyle(null);
      expect(meshes.first.material, same(original));
      expect(meshes.first.visible, isTrue);
      expect(Raycaster().intersectScene(scene, ray), hasLength(1));
    },
  );
  test(
    'streamed styles survive arrival and reset across cached tiles',
    () async {
      final resolver = MemoryResolver({'/batch': batchModel()});
      final style = TileStyle3D((f) => TileFeatureStyle3D(show: f.id == 1));
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(refine: 'REPLACE', uri: 'batch')),
        services: AssetServices(resolver: resolver),
        style: style,
      );
      addTearDown(streamer.dispose);
      streamer.update(
        PerspectiveCamera(
          position: const Vec3(0, -30, 0),
          up: const Vec3(0, 0, 1),
        ),
        const ViewportMetrics(100, 100),
      );
      await settle(streamer);
      expect(streamer.failures, isEmpty);
      final meshes = featureMeshes(streamer.visible.values.single);
      expect(meshes.map((m) => m.visible), [false, true]);
      expect(
        () => streamer.setStyle(TileStyle3D((f) => throw StateError('Failed'))),
        throwsStateError,
      );
      expect(streamer.style, same(style));
      streamer.setStyle(null);
      expect(meshes.every((m) => m.visible), isTrue);
    },
  );
  test(
    'binary batch values preserve vectors and nested JSON immutably',
    () async {
      final binary = ByteData(16);
      for (var i = 0; i < 4; i++) {
        binary.setFloat32(i * 4, (i + 1).toDouble(), Endian.little);
      }
      final instance = (await loadFeature(
        batchModel(
          properties: {
            'position': {
              'byteOffset': 0,
              'componentType': 'FLOAT',
              'type': 'VEC2',
            },
            'details': [
              {
                'tags': ['A'],
              },
              null,
            ],
          },
          batchBinary: binary.buffer.asUint8List(),
        ),
      )).instantiate();
      expect(instance.features.last.properties['position'], [3, 4]);
      final detail = instance.features.first.properties['details'] as Map;
      expect(() => (detail['tags'] as List).clear(), throwsUnsupportedError);
    },
  );
  test('batch properties remain available for each feature', () async {
    final model = await loadFeature(batchModel());
    final instance = model.instantiate();
    final features = instance.features;
    expect(features.map((f) => f.properties['name']), ['North', 'South']);
  });
  test(
    'batch counts, binary ranges and hierarchy errors cannot be hidden',
    () async {
      for (final bytes in [
        batchModel(
          count: 1,
          properties: {
            'name': ['Only'],
          },
        ),
        batchModel(
          properties: {
            'name': ['Only'],
          },
        ),
        batchModel(
          properties: {
            'height': {
              'byteOffset': 8,
              'componentType': 'FLOAT',
              'type': 'SCALAR',
            },
          },
        ),
        batchModel(
          properties: {
            'extensions': {'3DTILES_batch_table_hierarchy': {}},
          },
        ),
      ]) {
        await expectLater(
          loadFeature(bytes),
          throwsA(isA<AssetLoadException>()),
        );
      }
    },
  );
}
