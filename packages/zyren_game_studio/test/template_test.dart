import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test(
    'missing pinned template asset fails and recovers after import',
    () async {
      final uri = Uri.parse('game:///template/marker.bin');
      final bundle = await PipelineBuilder(resolver: _Bytes(uri)).build(
        entrySourceId: 'marker',
        sources: [PipelineSource(sourceId: 'marker', revision: '1', uri: uri)],
      );
      final reference = PipelineAssetReference.fromBundle(bundle);
      final authoring = createGameDevelopmentAuthoring();
      final template = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'import');
      final document = template.document.copyWith(
        assets: [
          StudioAsset(
            id: 'marker',
            label: 'Marker',
            provider: 'zyren.pipeline',
            reference: reference.toJson(),
          ),
        ],
      );
      final store = <String, PipelineBundle>{};
      final compiler = GameProjectCompiler(
        registry: authoring.registry,
        assets: PipelineAssetLibrary(
          readBundle: (version, _) async => store[version],
        ),
      );
      Future<GameBuildResult> build() => compiler.compile(
        documents: [document],
        startupLevel: 'main',
        profile: GameBuildProfile(id: 'native'),
      );
      final missing = await build();
      expect(missing.status, GameBuildStatus.failed);
      expect(missing.artifact, isNull);
      store[bundle.version] = bundle;
      final retry = await build();
      expect(
        retry.status,
        GameBuildStatus.ready,
        reason: retry.diagnostics.join('\n'),
      );
      final exported = GameExportManifest.decodeBundle(
        retry.artifact!.bundle.encode(),
        authoring.registry,
      );
      expect(exported.bundle.resource('marker').bytes, [1, 2, 3]);
    },
  );
  test(
    'templates save reopen compile and load independently offline',
    () async {
      final authoring = createGameDevelopmentAuthoring();
      for (final kind in GameTemplateKind.values) {
        final result = GameTemplate(
          kind,
          authoring,
        ).create(projectId: kind.name);
        final saved = StudioDocument.decode(result.document.encode());
        expect(authoring.validate(saved), isEmpty);
        final compiled =
            await GameProjectCompiler(
              registry: authoring.registry,
              assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
            ).compile(
              documents: [saved],
              startupLevel: 'main',
              profile: GameBuildProfile(id: 'native'),
            );
        expect(
          compiled.status,
          GameBuildStatus.ready,
          reason: compiled.diagnostics.join('\n'),
        );
        final offline = GameExportManifest.decodeBundle(
          compiled.artifact!.bundle.encode(),
          authoring.registry,
        );
        final manager = GameLevelManager(
          project: offline.project,
          resolver: offline.offlineResolver(),
          seed: 7,
          systems: (_) => [],
        );
        await manager.load('main', capabilities: {});
        expect(
          manager.session!.entities.entities.any(
            (e) => e.handle.id == 'player',
          ),
          isTrue,
        );
        await manager.close();
      }
    },
  );
  test(
    'shared navigation bake records sources and becomes stale after movement',
    () {
      final authoring = createGameDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'nav').document;
      final geometry = NavigationGeometry(
        sourceId: 'ground',
        revision: '1',
        vertices: [
          const Vec3(-3, 0, -3),
          const Vec3(3, 0, -3),
          const Vec3(3, 0, 3),
          const Vec3(-3, 0, 3),
        ],
        triangles: [
          [0, 2, 1],
          [0, 3, 2],
        ],
      );
      final baked = GameLevelAuthoring(
        authoring,
      ).bakeNavigation(document, [geometry]);
      expect(baked.mesh.cells, isNotEmpty);
      expect(baked.isCurrent(StudioDocument.decode(document.encode())), isTrue);
      expect(baked.toJson()['sources'], hasLength(1));
      final moved = StudioAuthoring.updateNode(
        document,
        'ground',
        StudioOverride(position: const Vec3(0, -1, 0)),
      );
      expect(baked.isCurrent(moved), isFalse);
      final changedCollider = GameLevelAuthoring(authoring).bindCollider(
        document,
        'ground',
        GameColliderDefinition(motion: GameBodyMotion.dynamic),
      );
      expect(baked.isCurrent(changedCollider), isFalse);
    },
  );
}

class _Bytes implements ByteSourceResolver {
  final Uri uri;
  _Bytes(this.uri);
  @override
  Future<ResolvedSource> read(Uri requested, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    if (requested != uri) throw StateError('Unexpected fixture request.');
    return ResolvedSource(
      effectiveUri: uri,
      bytes: Uint8List.fromList([1, 2, 3]),
    );
  }
}
