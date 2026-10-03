// Regenerate the authored reference projects and their offline runtime bundles.
import 'dart:io';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the GameLab output directory.');
  }
  final output = Directory(args.single).absolute;
  final authoring = createGameDevelopmentAuthoring();
  await Directory('${output.path}/projects').create(recursive: true);
  await Directory('${output.path}/games').create(recursive: true);
  for (final kind in GameTemplateKind.values) {
    final document = GameTemplate(
      kind,
      authoring,
    ).create(projectId: kind.name).document;
    final path = '${output.path}/projects/${kind.name}.zyren.json';
    await File(path).writeAsString(document.encode(), flush: true);
    final reopened = StudioDocument.decode(await File(path).readAsString());
    final compiled =
        await GameProjectCompiler(
          registry: authoring.registry,
          assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
        ).compile(
          documents: [reopened],
          startupLevel: 'main',
          profile: GameLevelAuthoring(authoring).profile(reopened),
        );
    if (compiled.status != GameBuildStatus.ready) {
      throw StateError(compiled.diagnostics.join('\n'));
    }
    await File(
      '${output.path}/games/${kind.name}.zygame',
    ).writeAsBytes(compiled.artifact!.bundle.encode(), flush: true);
    stdout.writeln('${kind.name}: ${compiled.artifact!.project.buildId}');
  }
}
