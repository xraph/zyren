import 'dart:convert';
import 'dart:io';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'visual_v2_scenario.dart';
import 'worker_transport.dart';

Map<String, GameTrainingScenario> visualV2TrainCatalog() {
  final guard = visualV2GuardScenario();
  return {guard.id: guard};
}

/// Separate TRAIN entry preserves all previously frozen worker/catalog pins.
Future<void> runVisualV2Worker(List<String> args) async {
  if (args.length == 1 && args.single == '--profile-specs') {
    stdout.writeln(
      jsonEncode([
        for (final family in ['guard', 'vehicle'])
          for (final mode in ['rgb', 'depth', 'combined'])
            {
              'profile': VisualNavigationProfile(
                family: family,
                mode: mode,
              ).toJson(),
              'observation': VisualNavigationProfile(
                family: family,
                mode: mode,
              ).spec.toJson(),
              'activationAllowed': false,
            },
      ]),
    );
    return;
  }
  if (args.isNotEmpty) {
    throw ArgumentError('Unknown visual v2 TRAIN worker flag.');
  }
  await runTrainingProtocol(
    visualV2TrainCatalog,
    capabilities: const {
      'structured',
      'native-physics',
      'native-camera',
      'TRAIN-visual-navigation-v2',
    },
  );
}
