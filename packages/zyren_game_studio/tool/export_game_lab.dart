// Regenerate authored reference projects and their offline runtime bundles.
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_studio/ai_authoring.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    throw ArgumentError(
      'Pass the GameLab output directory and optional accepted model directory.',
    );
  }
  final output = Directory(args.first).absolute;
  final authoring = createGameAiDevelopmentAuthoring();
  final artifacts = <String, ModelArtifact>{};
  final bundles = <String, PipelineBundle>{};
  final pins = <String, PipelineAssetReference>{};
  if (args.length == 2) {
    for (final family in ['guard', 'vehicle']) {
      final folder = Directory('${args[1]}/$family');
      final manifest = await File('${folder.path}/bundle.json').readAsBytes();
      final files = {
        for (final name in ModelArtifact.fileNames)
          name: await File('${folder.path}/$name').readAsBytes(),
      };
      final artifact = ModelArtifact.decode(manifest, files);
      if (artifact.family != family) {
        throw StateError('Wrong accepted model family.');
      }
      artifacts[family] = artifact;
      final hash = artifact.contract.model.sha256;
      final prefix = 'model.$hash.';
      final bytes = {'bundle.json': manifest, ...files};
      final uris = {
        for (final name in bytes.keys) name: Uri.parse('model:///$hash/$name'),
      };
      final bundle =
          await PipelineBuilder(
            resolver: _ModelFiles({
              for (final entry in bytes.entries) uris[entry.key]!: entry.value,
            }),
          ).build(
            entrySourceId: '${prefix}actor.onnx',
            sources: [
              for (final entry in bytes.entries)
                PipelineSource(
                  sourceId: '$prefix${entry.key}',
                  revision: sha256.convert(entry.value).toString(),
                  uri: uris[entry.key]!,
                ),
            ],
          );
      bundles[bundle.version] = bundle;
      pins[family] = PipelineAssetReference.fromBundle(bundle);
    }
  }
  await Directory('${output.path}/projects').create(recursive: true);
  await Directory('${output.path}/games').create(recursive: true);
  for (final kind in GameTemplateKind.values) {
    var document = GameTemplate(
      kind,
      authoring,
    ).create(projectId: kind.name).document;
    final level = GameLevelAuthoring(authoring);
    final family = kind == GameTemplateKind.exploration ? 'guard' : 'vehicle';
    final artifact = artifacts[family];
    final actor = family == 'guard' ? 'guard' : 'driver';
    document = document.copyWith(
      nodes: [
        ...document.nodes,
        StudioNode(
          id: actor,
          label: family == 'guard' ? 'Guard' : 'AI buggy',
          position: family == 'guard'
              ? const Vec3(4, 1.5, 4)
              : const Vec3(-5, 1, 0),
          size: family == 'guard'
              ? const Vec3(.6, 1.8, .6)
              : const Vec3(1.4, .7, 2),
          color: 0x9b7bea,
        ),
        StudioNode(
          id: 'perception-wall',
          label: 'Occlusion wall',
          position: const Vec3(3, 1.5, 2),
          size: const Vec3(3, 3, .3),
          color: 0x657380,
        ),
        if (family == 'vehicle')
          StudioNode(
            id: 'moving-hazard',
            label: 'Moving hazard',
            position: const Vec3(-5, .6, 9),
            size: const Vec3(1.2, 1.2, 1.2),
            color: 0xed7753,
          ),
      ],
    );
    document = level.bindCollider(
      document,
      actor,
      family == 'guard'
          ? GameColliderDefinition(
              shape: GameColliderShape.capsule,
              motion: GameBodyMotion.kinematic,
            )
          : GameColliderDefinition(
              motion: GameBodyMotion.dynamic,
              halfExtents: const Vec3(.7, .35, 1),
              mass: 1200,
            ),
    );
    document = authoring.addComponent(
      document,
      actor,
      authoring
          .descriptors[family == 'guard' ? 'game.character' : 'game.vehicle']!
          .create(),
    );
    document = authoring.addComponent(
      document,
      actor,
      GameComponentRecord('game.ai', 1, {
        'profile': family,
        'brain': artifact == null ? 'scripted' : 'hybrid',
        if (artifact != null) 'modelHash': artifact.contract.model.sha256,
        if (artifact != null) 'modelReference': pins[family]!.toJson(),
      }),
    );
    document = level.bindCollider(
      document,
      'perception-wall',
      GameColliderDefinition(halfExtents: const Vec3(1.5, 1.5, .15)),
    );
    if (family == 'vehicle') {
      document = level.bindCollider(
        document,
        'moving-hazard',
        GameColliderDefinition(
          motion: GameBodyMotion.kinematic,
          halfExtents: const Vec3(.6, .6, .6),
        ),
      );
    }
    if (artifact != null) {
      final original = level.profile(document);
      document = level.setProfile(
        document,
        GameBuildProfile(
          id: original.id,
          fixedHz: artifact.fixedHz,
          capabilities: original.capabilities,
        ),
      );
    }
    final path = '${output.path}/projects/${kind.name}.zyren.json';
    await File(path).writeAsString(document.encode(), flush: true);
    final reopened = StudioDocument.decode(await File(path).readAsString());
    final compiled =
        await GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(
            readBundle: (version, _) async => bundles[version],
          ),
        ).compile(
          documents: [reopened],
          startupLevel: 'main',
          profile: level.profile(reopened),
          models: gameAiModelReferences(authoring, reopened),
        );
    if (compiled.status != GameBuildStatus.ready) {
      throw StateError(compiled.diagnostics.join('\n'));
    }
    await File(
      '${output.path}/games/${kind.name}.zygame',
    ).writeAsBytes(compiled.artifact!.bundle.encode(), flush: true);
    stdout.writeln(
      '${kind.name}: ${compiled.artifact!.project.buildId} (${artifact == null ? 'scripted' : artifact.contract.model.sha256})',
    );
  }
}

final class _ModelFiles implements ByteSourceResolver {
  final Map<Uri, Uint8List> files;
  _ModelFiles(this.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    final bytes = files[uri];
    if (bytes == null) {
      throw StateError('Model resource is not in the accepted artifact.');
    }
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}
