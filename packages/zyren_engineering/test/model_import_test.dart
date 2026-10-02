import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import '../example/model_review.dart';
import '../../zyren/test/support/fakes.dart';

class ModelSource implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(
        effectiveUri: uri,
        bytes: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'asset': {'version': '2.0'},
              'nodes': [
                {
                  'name': 'Duplicate',
                  'translation': [2, 0, 0],
                },
                {'name': 'Duplicate'},
              ],
              'scenes': [
                {
                  'nodes': [0, 1],
                },
              ],
              'scene': 0,
            }),
          ),
        ),
      );
}

void main() {
  test(
    'real glTF decode and sidecar preserve review identity across instances',
    () async {
      final assets = AssetScope(
        services: AssetServices(resolver: ModelSource()),
      );
      final scene = Scene();
      final review = SceneEngineeringPlugin(
        document: EngineeringDocument(id: 'review'),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [review],
      );
      addTearDown(() async {
        await engine.dispose();
        assets.close();
      });
      final sidecar = jsonEncode({
        'schemaVersion': 1,
        'modelVersion': 'export-17',
        'entries': [
          {
            'id': 'cad-part-guid',
            'label': 'Housing',
            'properties': {},
            'path': [0],
          },
        ],
      });
      Future<Group> load() => importReviewModel(
        assets: assets,
        scene: scene,
        review: review,
        source: Uri.parse('https://example.test/model.gltf'),
        modelVersion: 'export-17',
        sidecar: sidecar,
      );
      final first = await load();
      review.putAnnotation(
        EngineeringAnnotation(
          id: 'note',
          objectId: 'cad-part-guid',
          text: 'Inspect seal',
          anchor: const Vec3(.25, 0, 0),
        ),
      );
      final second = await load();
      expect(review.objectFor('cad-part-guid'), same(second.children[0]));
      expect(review.idFor(first.children[0]), isNull);
      expect(review.worldAnchor('note')!.x, 2.25);
      scene.remove(first);
      expect(review.worldAnchor('note')!.x, 2.25);
    },
  );
}
