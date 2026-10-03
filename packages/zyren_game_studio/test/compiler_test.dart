import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

class Link extends GameComponentCodec<Object> {
  @override
  String get type => 'test.link';
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {
    if (data['target'] is! String || data['value'] is! int) {
      throw FormatException('link');
    }
  }

  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) => [
    GameLocalReference(['target'], data['target'] as String),
  ];
  @override
  Map<String, Object?> migrate(int v, Map<String, Object?> data) =>
      throw FormatException('version');
  @override
  Object factory(Map<String, Object?> data) => data;
}

GameRegistry registry() => GameRegistry()..registerComponent(Link());
StudioExtensionRecord record(
  GameDocumentCodec codec,
  List<GameEntityRecord> entities,
) => codec.write(
  GameDocumentData(projectId: 'g', levelId: 'l', entities: entities),
);
StudioDocument document(GameDocumentCodec codec, {bool nested = false}) =>
    StudioDocument(
      id: 'doc',
      title: 'Game',
      nodes: [
        StudioNode(
          id: 'instance',
          label: 'Instance',
          kind: StudioNodeKind.prefab,
          prefabId: nested ? 'outer' : 'inner',
          extensionOverrides: {
            'zyren.game': {
              'entities': {
                nested ? 'nested/kid' : 'kid': {
                  'components': {
                    'test.link': {'value': 2},
                  },
                },
              },
            },
          },
        ),
      ],
      extensions: {'zyren.game': record(codec, [])},
      prefabs: [
        StudioPrefab(
          id: 'inner',
          version: '1',
          label: 'Inner',
          nodes: [StudioNode(id: 'kid', label: 'Kid')],
          extensions: {
            'zyren.game': record(codec, [
              GameEntityRecord(
                id: 'kid',
                nodeId: 'kid',
                components: [
                  GameComponentRecord('test.link', 1, {
                    'target': 'kid',
                    'value': 1,
                  }),
                ],
              ),
            ]),
          },
        ),
        if (nested)
          StudioPrefab(
            id: 'outer',
            version: '1',
            label: 'Outer',
            nodes: [
              StudioNode(
                id: 'nested',
                label: 'Nested',
                kind: StudioNodeKind.prefab,
                prefabId: 'inner',
              ),
            ],
          ),
      ],
    );
void main() {
  test(
    'resolved Pipeline asset and model bytes export for offline runtime',
    () async {
      final uri = Uri.parse('game:///asset/model.bin');
      final bundle =
          await PipelineBuilder(
            resolver: Bytes(uri, Uint8List.fromList([1, 2, 3])),
          ).build(
            entrySourceId: 'document.model',
            sources: [
              PipelineSource(
                sourceId: 'document.model',
                revision: 'pin',
                uri: uri,
              ),
            ],
          );
      final pin = PipelineAssetReference.fromBundle(bundle);
      final codecs = registry(), codec = GameDocumentCodec(registry());
      final source = document(codec).copyWith(
        assets: [
          StudioAsset(
            id: 'model',
            label: 'Model',
            provider: 'zyren.pipeline',
            reference: pin.toJson(),
          ),
        ],
      );
      final compiler = GameProjectCompiler(
        registry: codecs,
        assets: PipelineAssetLibrary(
          readBundle: (version, _) async =>
              version == bundle.version ? bundle : null,
        ),
      );
      final built = await compiler.compile(
        documents: [source],
        startupLevel: 'l',
        profile: GameBuildProfile(id: 'native'),
        models: {'brain': pin},
      );
      expect(built.status, GameBuildStatus.ready);
      expect(built.artifact!.project.assets.single.id, 'document.model');
      final offline = GameExportManifest.decodeBundle(
        built.artifact!.bundle.encode(),
        codecs,
      );
      final manager = GameLevelManager(
        project: offline.project,
        resolver: offline.offlineResolver(),
        seed: 1,
        systems: (_) => [],
      );
      await manager.load('l', capabilities: {});
      expect(manager.activeAssetCount, 1);
      await manager.close();
    },
  );
  test(
    'structural remap preserves custom identity and declared references consistently',
    () {
      final codec = GameDocumentCodec(registry());
      final source = record(codec, [
        GameEntityRecord(
          id: 'named/guard',
          nodeId: 'body',
          components: [
            GameComponentRecord('test.link', 1, {
              'target': 'named/guard',
              'value': 1,
            }),
          ],
        ),
      ]);
      final remapped = codec
          .read(codec.remapNodeIds(source, {'body': 'copy/body'}))
          .entities
          .single;
      expect(remapped.id, 'copy%2Fbody/named%2Fguard');
      expect(remapped.nodeId, 'copy/body');
      expect(remapped.components.single.data['target'], remapped.id);
      final collision = record(codec, [
        GameEntityRecord(id: 'named/guard', nodeId: 'body'),
        GameEntityRecord(id: remapped.id),
      ]);
      expect(
        () => codec.read(codec.remapNodeIds(collision, {'body': 'copy/body'})),
        throwsFormatException,
      );
    },
  );
  test(
    'prefab expansion remaps declared references and applies relative nested overrides',
    () {
      final codec = GameDocumentCodec(registry());
      for (final nested in [false, true]) {
        final data = codec.expand(document(codec, nested: nested));
        final entity = data.entities.single;
        expect(entity.nodeId, nested ? 'instance/nested/kid' : 'instance/kid');
        expect(entity.components.single.data['target'], entity.id);
        expect(entity.components.single.data['value'], 2);
      }
    },
  );
  test('compile uses Pipeline receipt reuse and offline export pins', () async {
    final codecs = registry();
    final codec = GameDocumentCodec(codecs);
    final compiler = GameProjectCompiler(
      registry: codecs,
      assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
    );
    final first = await compiler.compile(
      documents: [document(codec)],
      startupLevel: 'l',
      profile: GameBuildProfile(id: 'native', capabilities: ['native']),
    );
    expect(first.status, GameBuildStatus.ready);
    expect(first.artifact!.project.sceneNodes['l'], hasLength(2));
    expect(first.artifact!.project.levels.single.entities, hasLength(1));
    final second = await compiler.compile(
      documents: [document(codec)],
      startupLevel: 'l',
      profile: GameBuildProfile(id: 'native', capabilities: ['native']),
      previous: first.pipelineResult,
    );
    expect(second.pipelineResult!.reused, ['game.recipe']);
    final restored = GameExportManifest.decodeBundle(
      first.artifact!.bundle.encode(),
      codecs,
    );
    expect(restored.project.buildId, first.artifact!.project.buildId);
    final manager = GameLevelManager(
      project: restored.project,
      resolver: restored.offlineResolver(),
      seed: 1,
      systems: (_) => [],
    );
    await expectLater(manager.load('l', capabilities: {}), throwsStateError);
    expect(manager.session, isNull);
    await manager.load('l', capabilities: {'native'});
    expect(manager.session!.entities.length, 1);
    await manager.close();
  });
  test(
    'failed and cancelled builds expose no artifact and preserve old cache',
    () async {
      final codecs = registry();
      final codec = GameDocumentCodec(codecs);
      final cache = PipelineCache();
      final compiler = GameProjectCompiler(
        registry: codecs,
        cache: cache,
        assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
      );
      final good = await compiler.compile(
        documents: [document(codec)],
        startupLevel: 'l',
        profile: GameBuildProfile(id: 'native'),
      );
      final bad = document(codec).copyWith(
        extensions: {
          'zyren.game': record(codec, [
            GameEntityRecord(
              id: 'bad',
              components: [GameComponentRecord('unknown.required', 1, {})],
            ),
          ]),
        },
      );
      final failed = await compiler.compile(
        documents: [bad],
        startupLevel: 'l',
        profile: GameBuildProfile(id: 'native'),
      );
      expect(failed.status, GameBuildStatus.failed);
      expect(failed.artifact, isNull);
      expect(cache.peek(good.artifact!.bundle.version), isNotNull);
      final token = PipelineCancellation()..cancel();
      final cancelled = await compiler.compile(
        documents: [document(codec)],
        startupLevel: 'l',
        profile: GameBuildProfile(id: 'native'),
        cancellation: token,
      );
      expect(cancelled.status, GameBuildStatus.cancelled);
      expect(cancelled.artifact, isNull);
    },
  );
}

class Bytes implements ByteSourceResolver {
  final Uri uri;
  final Uint8List bytes;
  Bytes(this.uri, this.bytes);
  @override
  Future<ResolvedSource> read(Uri requested, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}
