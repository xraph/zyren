import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/cad_bundle.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import '../example/model_review.dart';
import '../../zyren/test/support/fakes.dart';

class BundleSource implements ByteSourceResolver {
  final Uint8List bytes;
  BundleSource(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

void main() {
  final fixtures = Directory('packages/zyren_engineering/test/fixtures/cad');
  test('rejects a sidecar paired with different model bytes', () async {
    final a = await EngineeringCadBundle.read(
      Directory('${fixtures.path}/original'),
    );
    final b = await EngineeringCadBundle.read(
      Directory('${fixtures.path}/moved'),
    );
    expect(
      () => EngineeringCadBundle.decode(a.bytes, b.sidecar),
      throwsFormatException,
    );
    expect(
      () => EngineeringCadBundle.decode(a.bytes, '{}'),
      throwsFormatException,
    );
  });
  test(
    'converted IFC loads real geometry and preserves anchors after reload',
    () async {
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
      final scopes = <AssetScope>[];
      addTearDown(() async {
        await engine.dispose();
        for (final scope in scopes) {
          scope.close();
        }
      });
      Future<Group> load(String name) async {
        final bundle = await EngineeringCadBundle.read(
          Directory('${fixtures.path}/$name'),
        );
        final assets = AssetScope(
          services: AssetServices(resolver: BundleSource(bundle.bytes)),
        );
        scopes.add(assets);
        return importReviewModel(
          assets: assets,
          scene: scene,
          review: review,
          source: Uri.parse('memory:model.glb'),
          modelVersion: bundle.version,
          sidecar: bundle.sidecar,
        );
      }

      final first = await load('original');
      final id = review.document.objects.keys.single;
      expect(first.children, isNotEmpty);
      var meshes = 0;
      void visit(Object3D object) {
        if (object is Mesh) meshes++;
        for (final child in object.children) {
          visit(child);
        }
      }

      visit(first);
      expect(meshes, greaterThan(0));
      review.putAnnotation(
        EngineeringAnnotation(
          id: 'seal',
          objectId: id,
          text: 'Inspect seal',
          anchor: const Vec3(.25, .1, 0),
        ),
      );
      final oldAnchor = review.worldAnchor('seal')!;
      final second = await load('moved');
      scene.remove(first);
      expect(review.objectFor(id), same(second.children.first));
      expect(review.document.objects[id]!.label, 'Housing renamed');
      expect(review.worldAnchor('seal')!.x - oldAnchor.x, closeTo(3, .00001));
      expect(
        review.document.annotations['seal']!.anchor,
        const Vec3(.25, .1, 0),
      );
    },
  );
}
