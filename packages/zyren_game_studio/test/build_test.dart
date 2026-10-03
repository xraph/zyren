import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/export_io.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

void main() {
  test(
    'host validation refuses stale navigation before creating a job',
    () async {
      final authoring = createGameDevelopmentAuthoring();
      final doc = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'validation').document;
      final commands = GameBuildCommands(
        compiler: GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
        ),
        documents: () => [doc],
        revision: () => 1,
        startupLevel: () => 'main',
        profile: () => GameLevelAuthoring(authoring).profile(doc),
        allows: (_) => true,
        isAvailable: () => true,
        outputLabel: 'Choose output',
        outputLocation: () => '/host/selected/game.zygame',
        hostValidation: () => [
          'Navigation is stale. Bake it again before export.',
        ],
        publish: (_, token, check) async =>
            fail('Invalid data must not publish.'),
      );
      expect(commands.currentOutputLabel, '/host/selected/game.zygame');
      expect(
        commands.startBuild(expectedRevision: 1, requestId: 'invalid'),
        isA<InvalidBuildResult>(),
      );
      expect(commands.jobs, isEmpty);
      await commands.close();
    },
  );

  test(
    'denied and stale requests create no jobs or output directory',
    () async {
      final root = await Directory.systemTemp.createTemp('game-build-');
      final authoring = createGameDevelopmentAuthoring();
      final doc = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'export').document;
      var granted = false;
      final target = File('${root.path}/output/game.zygame');
      final commands = GameBuildCommands(
        compiler: GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
        ),
        documents: () => [doc],
        revision: () => 4,
        startupLevel: () => 'main',
        profile: () => GameLevelAuthoring(authoring).profile(doc),
        allows: (_) => granted,
        isAvailable: () => true,
        publish: GameFilePublisher(target).publish,
        outputLabel: target.path,
      );
      try {
        expect(
          commands.startBuild(expectedRevision: 4, requestId: 'denied'),
          isA<DeniedBuildResult>(),
        );
        granted = true;
        expect(
          commands.startBuild(expectedRevision: 3, requestId: 'stale'),
          isA<StaleBuildResult>(),
        );
        expect(commands.jobs, isEmpty);
        expect(await target.parent.exists(), isFalse);
        final first =
            commands.startBuild(expectedRevision: 4, requestId: 'build')
                as StartedBuildResult;
        final again =
            commands.startBuild(expectedRevision: 4, requestId: 'build')
                as StartedBuildResult;
        expect(identical(first.job, again.job), isTrue);
        await first.job.done;
        expect(first.job.state, PipelineBuildState.succeeded);
        expect(commands.jobs, hasLength(1));
        final exported = GameExportManifest.decodeBundle(
          await target.readAsBytes(),
          authoring.registry,
        );
        expect(exported.project.project.id, 'export');
        expect(exported.bundle.version, first.job.result!.bundle.version);
      } finally {
        await commands.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('publication rechecks document revision and live grants', () async {
    for (final revoke in [false, true]) {
      final root = await Directory.systemTemp.createTemp('game-stale-');
      final authoring = createGameDevelopmentAuthoring();
      final doc = GameTemplate(
        GameTemplateKind.vehiclePlayground,
        authoring,
      ).create(projectId: 'race').document;
      var revision = 1, granted = true;
      final ready = Completer<void>(), release = Completer<void>();
      final target = File('${root.path}/output/game.zygame');
      final publisher = GameFilePublisher(target);
      final commands = GameBuildCommands(
        compiler: GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
        ),
        documents: () => [doc],
        revision: () => revision,
        startupLevel: () => 'main',
        profile: () => GameLevelAuthoring(authoring).profile(doc),
        allows: (_) => granted,
        isAvailable: () => true,
        outputLabel: target.path,
        publish: (bundle, token, check) async {
          ready.complete();
          await release.future;
          await publisher.publish(bundle, token, check);
        },
      );
      try {
        final result =
            commands.startBuild(expectedRevision: 1, requestId: 'race')
                as StartedBuildResult;
        await ready.future;
        if (revoke) {
          granted = false;
        } else {
          revision++;
        }
        release.complete();
        await result.job.done;
        expect(result.job.state, PipelineBuildState.failed);
        expect(await target.exists(), isFalse);
        expect(await target.parent.exists(), isFalse);
      } finally {
        await commands.close();
        await root.delete(recursive: true);
      }
    }
  });
}
