import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  final root = Directory('tool/zyren_train').existsSync() ? '' : '../../';
  for (final mode in ['rgb', 'depth', 'combined']) {
    test(
      '$mode registered visual plan matches exact locked native ABI and gates',
      () {
        final bytes = File(
          '${root}tool/zyren_train/qualification/visual-2026-10-03/plans/$mode.json',
        ).readAsBytesSync();
        final hash = sha256.convert(bytes).toString();
        expect(visualModelEvaluationPlanHashes[mode], {hash});
        final plan = jsonDecode(utf8.decode(bytes)) as Map;
        expect(
          plan['worker_sha256'],
          'cc102a7b7625e89f7ee9e3805b3f722777ad43a003103514bc103d0afb536706',
        );
        expect((plan['worker_native_sha256'] as Map).length, 5);
        expect(plan['targets'], {
          'guard': {
            'collision_rate': null,
            'success_lower95': .85,
            'success_rate': .9,
          },
          'vehicle': {
            'collision_rate': .02,
            'success_lower95': .9,
            'success_rate': .95,
          },
        });
        final cases = (plan['cases'] as List).cast<Map>();
        for (final family in ['guard', 'vehicle']) {
          final profile = TrainingVisualProfiles.forFamily(
            family: family,
            mode: mode,
          );
          final seeds = <int>[];
          for (final row in cases.where((c) => c['family'] == family)) {
            final scenario = row['scenario'] as Map;
            expect(scenario['observation_schema_hash'], profile.spec.hash);
            expect(scenario['action_schema_hash'], profile.decoder.spec.hash);
            expect(scenario['partition'], 'test');
            expect(scenario['settings']['fixed_hz'], profile.fixedHz);
            expect(scenario['control_cadence'], 1);
            expect(scenario['latency_ticks'], 1);
            seeds.addAll((row['seeds'] as List).cast<int>());
          }
          expect(seeds.length, 200);
          expect(seeds.toSet().length, greaterThanOrEqualTo(20));
          expect(seeds.every((n) => n >= 20001), isTrue);
        }
      },
    );
  }
}
