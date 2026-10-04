import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_game_lab/benchmark.dart';
import 'package:zyren_game_lab/benchmark_host.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'measure the exported game on its native presenter',
    (tester) async {
      const id = String.fromEnvironment(
        'GAME_BENCHMARK_PROFILE',
        defaultValue: 'reference-guard',
      );
      final profile = gameBenchmarkProfiles[id];
      if (profile == null) {
        throw ArgumentError('Unknown benchmark profile: $id');
      }
      const asset = String.fromEnvironment(
        'GAME_BENCHMARK_ASSET',
        defaultValue: 'games/exploration.zygame',
      );
      final data = await rootBundle.load(asset);
      final host = GameBenchmarkHost(
        profile: profile,
        bundle: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        device: const String.fromEnvironment('GAME_BENCHMARK_DEVICE'),
        buildHash: const String.fromEnvironment('GAME_BENCHMARK_BUILD_HASH'),
        physicalDevice: const bool.fromEnvironment('GAME_BENCHMARK_PHYSICAL'),
      );
      try {
        await tester.runAsync(host.load);
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: GameBenchmarkView(host))),
        );
        const smoke = bool.fromEnvironment('GAME_BENCHMARK_SMOKE');
        final receipt = await tester.runAsync(() => host.execute(smoke: smoke));
        binding.reportData = receipt;
        expect(receipt, isNotNull);
        if (smoke) {
          // A short integration check deliberately cannot become qualification.
          expect(receipt!['status'], 'failed');
          expect(receipt['diagnostics'], contains('duration'));
          expect(receipt['frames'], greaterThan(0));
          expect(receipt['completedDecisions'], greaterThan(0));
          expect(
            (receipt['inferenceRoundTripMicros'] as Map)['count'],
            greaterThan(0),
          );
          expect(receipt['invalidActions'], 0);
          expect(receipt['staleActionsApplied'], 0);
          expect(receipt['cleanupVerified'], isTrue);
          expect(receipt['lifecycle'], hasLength(6));
        } else {
          expect(
            receipt!['status'],
            'passed',
            reason: '${receipt['diagnostics']}',
          );
        }
      } catch (error) {
        binding.reportData ??= {
          'schemaVersion': 1,
          'status': error is UnsupportedError ? 'unsupported' : 'failed',
          'profile': profile.toJson(),
          'diagnostics': ['$error'],
        };
        rethrow;
      } finally {
        await tester.runAsync(host.close);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    skip: !const bool.fromEnvironment('RUN_GAME_BENCHMARK'),
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
