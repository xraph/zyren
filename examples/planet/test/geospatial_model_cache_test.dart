import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_zyren/flutter_zyren.dart' show SceneRuntime;
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/layers/model_cache.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_pipeline/io.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import '../../../packages/zyren_pipeline/example/triangle_source.dart';

void main() {
  test(
    'geographic model reference reopens a verified bundle with offline dependencies',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-geo-model-',
      );
      final source = TriangleSource();
      final imageUri = TriangleSource.modelUri.resolve('albedo.png');
      var root = Directory.current;
      while (!File(
        '${root.path}/test_assets/images/corners.png',
      ).existsSync()) {
        if (root.parent.path == root.path) {
          throw StateError('Missing image fixture');
        }
        root = root.parent;
      }
      source.files[imageUri] = await File(
        '${root.path}/test_assets/images/corners.png',
      ).readAsBytes();
      final document =
          jsonDecode(utf8.decode(source.files[TriangleSource.modelUri]!))
              as Map<String, dynamic>;
      final buffer = ByteData(60);
      buffer.buffer.asUint8List().setRange(
        0,
        36,
        source.files[TriangleSource.bufferUri]!,
      );
      final uv = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0];
      for (var i = 0; i < uv.length; i++) {
        buffer.setFloat32(36 + i * 4, uv[i], Endian.little);
      }
      source.files[TriangleSource.bufferUri] = buffer.buffer.asUint8List();
      document['buffers'][0]['byteLength'] = 60;
      (document['bufferViews'] as List).add({
        'buffer': 0,
        'byteOffset': 36,
        'byteLength': 24,
      });
      (document['accessors'] as List).add({
        'bufferView': 1,
        'componentType': 5126,
        'count': 3,
        'type': 'VEC2',
      });
      document['meshes'][0]['primitives'][0]['attributes']['TEXCOORD_0'] = 1;
      document['images'] = [
        {'uri': 'albedo.png'},
      ];
      document['textures'] = [
        {'source': 0},
      ];
      document['materials'] = [
        {
          'pbrMetallicRoughness': {
            'baseColorTexture': {'index': 0},
          },
        },
      ];
      document['meshes'][0]['primitives'][0]['material'] = 0;
      source.files[TriangleSource.modelUri] = Uint8List.fromList(
        utf8.encode(jsonEncode(document)),
      );
      final bundle = await PipelineBuilder(resolver: source).build(
        entrySourceId: 'model',
        sources: [
          ...source.sources,
          PipelineSource(
            sourceId: 'albedo',
            revision: 'texture-r1',
            uri: imageUri,
          ),
        ],
      );
      final cache = FilePipelineCache(directory: directory, maxBytes: 1 << 20);
      expect(await cache.put(bundle, pin: true), isTrue);
      final reopened = FilePipelineCache(
        directory: directory,
        maxBytes: 1 << 20,
      );
      final store = GeoModelBundleStore(
        cache: reopened,
        version: bundle.version,
        authorizationPartition: 'workspace-demo',
        publishedAt: DateTime.utc(2026),
      );
      var calls = 0;
      final resolver = GeoResourceResolver(
        store: store,
        authorize: (k, _) => k.authorizationPartition == 'workspace-demo',
        fetch: (_, _) async {
          calls++;
          throw StateError('No transport');
        },
      );
      final resource = await resolver.read(
        store.key,
        GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        cancellation: LoadCancellationSource(),
      );
      final restored = PipelineBundle.decode(resource.bytes);
      expect(restored.version, bundle.version);
      final scope = restored.open(services: SceneRuntime.defaultAssetServices);
      final model = await scope.load(restored.gltfRequest()).result;
      final instance = model.instantiate();
      expect(instance.children, isNotEmpty);
      final meshes = <Mesh>[];
      void collect(Object3D object) {
        if (object is Mesh) meshes.add(object);
        for (final child in object.children) {
          collect(child);
        }
      }

      collect(instance);
      expect(
        meshes.single.material.colorMap!.image.levels.first,
        hasLength(16),
      );
      expect(calls, 0);
      await scope.close();
      await resolver.close();
      await store.close();
      expect((await reopened.inspect()).single.pinned, isTrue);
      await directory.delete(recursive: true);
    },
  );
}
