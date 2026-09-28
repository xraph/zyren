import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:test/test.dart';
import 'support/fixtures.dart';

class Sources implements ByteSourceResolver {
  final Uint8List bytes;
  Completer<void>? gate;
  int reads = 0;
  Sources(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads++;
    await gate?.future;
    context.cancellation.throwIfCancelled();
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

Mesh triangleIn(Object3D root) =>
    root.children.single.children.single.children.single as Mesh;
Future<ModelAsset> load(
  Uint8List bytes, {
  GltfOptions options = const GltfOptions(),
}) async {
  final scope = AssetScope(services: AssetServices(resolver: Sources(bytes)));
  addTearDown(scope.close);
  return scope.load(Gltf.asset('models/triangle.glb', options: options)).result;
}

void main() {
  test(
    'typed requests validate bundle paths and share by immutable options',
    () {
      final first = Gltf.asset('models/a b.glb');
      expect(first.uri, Uri.parse('asset:///models/a%20b.glb'));
      expect(
        first.loader.cacheKey,
        Gltf.asset('models/a b.glb').loader.cacheKey,
      );
      expect(
        first.loader.cacheKey,
        isNot(
          Gltf.asset(
            'models/a b.glb',
            options: const GltfOptions(
              materialMode: GltfMaterialMode.unlitDiagnostic,
            ),
          ).loader.cacheKey,
        ),
      );
      for (final path in [
        '',
        '/model.glb',
        '../model.glb',
        'a/../model.glb',
        r'a\model.glb',
      ]) {
        expect(() => Gltf.asset(path), throwsArgumentError);
      }
    },
  );
  test(
    'shared decode creates independent scoped templates and instances',
    () async {
      final sources = Sources(triangleModel())..gate = Completer<void>();
      final services = AssetServices(resolver: sources);
      final left = AssetScope(services: services),
          right = AssetScope(services: services);
      final first = left.load(Gltf.asset('models/triangle.glb'));
      final second = right.load(Gltf.asset('models/triangle.glb'));
      sources.gate!.complete();
      final a = await first.result, b = await second.result;
      expect(sources.reads, 1);
      expect(a, isNot(same(b)));
      final instance = a.instantiate(name: 'Pump A'), other = b.instantiate();
      expect(instance.name, 'Pump A');
      expect(other.name, 'Scene');
      expect(instance.children.single.position, const Vec3(1, 2, 3));
      final mesh = triangleIn(instance), sibling = triangleIn(other);
      expect(mesh.geometry, same(sibling.geometry));
      expect(mesh.material, same(sibling.material));
      expect(mesh.material.side, MaterialSide.front);
      expect(mesh.geometry.normals, [0, 0, 1, 0, 0, 1, 0, 0, 1]);
      mesh.position = const Vec3(10, 0, 0);
      mesh.material = UnlitMaterial(color: const Color3(0, 1, 0));
      expect(sibling.position, Vec3.zero);
      expect(sibling.material.color, const Color3(1, 0, 0));
      left.release(a);
      expect(a.isReleased, isTrue);
      expect(() => a.instantiate(), throwsStateError);
      expect(triangleIn(instance), same(mesh));
      expect(triangleIn(b.instantiate()).geometry, same(mesh.geometry));
      await left.close();
      await right.close();
      expect(b.isReleased, isTrue);
    },
  );
  test(
    'one cancelled consumer leaves the shared model available to its sibling',
    () async {
      final sources = Sources(triangleModel())..gate = Completer<void>();
      final scope = AssetScope(services: AssetServices(resolver: sources));
      final first = scope.load(Gltf.asset('triangle.glb'));
      final second = scope.load(Gltf.asset('triangle.glb'));
      final cancelled = expectLater(
        first.result,
        throwsA(isA<LoadCancelled>()),
      );
      first.cancel();
      sources.gate!.complete();
      await cancelled;
      expect((await second.result).instantiate().children, hasLength(1));
      expect(sources.reads, 1);
      await scope.close();
    },
  );
  test(
    'PBR requires explicit diagnostic mode and reports the approximation',
    () async {
      await expectLater(
        load(triangleModel(unlit: false)),
        throwsA(
          isA<AssetLoadException>()
              .having((e) => e.code, 'code', AssetLoadError.unsupportedFeature)
              .having((e) => e.fieldPath, 'path', 'materials[0]'),
        ),
      );
      final model = await load(
        triangleModel(unlit: false),
        options: const GltfOptions(
          materialMode: GltfMaterialMode.unlitDiagnostic,
        ),
      );
      expect(model.issues.any((i) => i.code == 'gltf.unlitDiagnostic'), isTrue);
      expect(triangleIn(model.instantiate()).material, isA<UnlitMaterial>());
    },
  );
  test(
    'malformed scene graphs fail with source and field diagnostics',
    () async {
      for (final changes in <Map<String, Object?>>[
        {
          'nodes': [
            {
              'children': [1],
            },
            {
              'children': [0],
            },
          ],
        },
        {
          'nodes': [
            {
              'children': [2],
            },
            {
              'children': [2],
            },
            {},
          ],
        },
        {
          'nodes': [
            {
              'children': [1],
            },
            {},
          ],
          'scenes': [
            {
              'nodes': [1],
            },
          ],
        },
        {
          'nodes': [
            {
              'rotation': [0, 0, 0, 0],
            },
          ],
        },
        {
          'nodes': [
            {'mesh': 8},
          ],
        },
      ]) {
        await expectLater(
          load(triangleModel(changes: changes)),
          throwsA(
            isA<AssetLoadException>()
                .having((e) => e.code, 'code', AssetLoadError.invalidData)
                .having(
                  (e) => e.issue.sourceUri,
                  'source',
                  Uri.parse('asset:///models/triangle.glb'),
                )
                .having((e) => e.fieldPath, 'path', isNotNull),
          ),
        );
      }
    },
  );
  test(
    'required extensions remain strict while optional ones report warnings',
    () async {
      final base = <String, Object?>{
        'asset': {'version': '2.0'},
      };
      final source = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            ...base,
            'extensionsUsed': ['KHR_draco_mesh_compression'],
            'extensionsRequired': ['KHR_draco_mesh_compression'],
          }),
        ),
      );
      final optional = await load(
        triangleModel(
          changes: {
            'extensionsUsed': ['KHR_materials_unlit', 'VENDOR_unknown'],
          },
        ),
      );
      expect(optional.issues.single.resourceLabel, 'extensionsUsed[1]');
      expect(optional.issues.single.sourceUri, isNotNull);
      await expectLater(
        load(source),
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.unsupportedFeature,
          ),
        ),
      );
    },
  );
}
