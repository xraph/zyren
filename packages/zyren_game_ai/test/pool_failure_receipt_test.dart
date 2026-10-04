import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'policy_test.dart' show PolicyFixture;

void main() {
  test(
    'a dispatched native batch cannot commit into a pooled replacement',
    () async {
      final fixture = PolicyFixture();
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      final worker = MlWorker();
      Map<String, int> nativeCounts() => {
        'sessions': const MlRuntime().diagnostics.liveSessions,
        'results': const MlRuntime().diagnostics.liveResults,
        'runs': const MlRuntime().diagnostics.activeRuns,
      };
      final baseline = nativeCounts();
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) =>
              File('../zyren_ml/test/fixtures/lstm_step.onnx').readAsBytes(),
        ),
        currentTick: () => tick,
      );
      final group = PolicyGroup(
        episodeId: 'pool',
        entities: fixture.entities,
        ml: ml,
      );
      PolicyBrain join(String id) => group.join(
        BrainIdentity(
          episodeId: 'pool',
          entity: fixture.entities.spawn(id),
          modelHash: model.sha256,
        ),
        fixture.contract(model, ActionDecoder.character()),
      );
      final old = join('recycled'), survivor = join('survivor');
      PolicyBrain? replacement;
      Future<void>? retired;
      late Map<String, Object?> before, after;
      StreamSubscription<MlWorkerEvent>? events;
      var nativeRuns = 0;
      Map<String, Object?> state(PolicyBrain brain) => {
        'identity': brain.identity.entity.toString(),
        'model': brain.identity.modelHash,
        'state': brain.state.snapshot().encode(),
      };
      try {
        events = worker.events.listen((event) {
          if (event.operation != 'run' || replacement != null) return;
          // This event comes from the native isolate after dispatch, before the
          // batch result is delivered. Reuse only the logical actor slot.
          expect(fixture.entities.despawn(old.identity.entity), isTrue);
          retired = group.leave(old.identity.entity);
          replacement = join('recycled');
          expect(
            replacement!.identity.entity.generation,
            greaterThan(old.identity.entity.generation),
          );
          before = state(replacement!);
        });
        final pending = <Future<BrainDecision?>>[];
        for (final brain in [old, survivor]) {
          brain.observe(fixture.frame(brain.identity, tick));
          pending.add(brain.request(fixture.context(brain, tick)));
        }
        final completedBefore = (await worker.diagnostics()).completedRuns!;
        await ml.flush();
        final decisions = await Future.wait(pending);
        await retired;
        expect(replacement, isNotNull);
        expect(decisions.first, isNull);
        expect(decisions.last, isNotNull);
        tick = 3;
        expect(
          survivor.decide(fixture.context(survivor, tick)).isFallback,
          isFalse,
        );
        expect(survivor.state.version, 1);
        after = state(replacement!);
        expect(after, before);
        expect(group.brainFor(old.identity.entity), isNull);
        nativeRuns =
            (await worker.diagnostics()).completedRuns! - completedBefore;
        expect(nativeRuns, greaterThan(0));
        // Recovery uses the replacement's own observation and new recurrent state.
        tick = 4;
        replacement!.observe(fixture.frame(replacement!.identity, tick));
        final retry = replacement!.request(fixture.context(replacement!, tick));
        await ml.flush();
        expect(await retry, isNotNull);
        tick = 6;
        expect(
          replacement!.decide(fixture.context(replacement!, tick)).isFallback,
          isFalse,
        );
        expect(replacement!.state.version, 1);
      } finally {
        await events?.cancel();
        await group.close();
        await ml.close();
      }
      expect(nativeCounts(), baseline);
      final path = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
      if (path != null) {
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': 1,
            'cases': {
              'leakage.pool-replacement': {
                'status': 'passed',
                'actualStatus': 'rejected',
                'before': before,
                'after': after,
                'completedNativeRuns': nativeRuns,
                'cleanupCounters': {
                  'before': baseline,
                  'after': nativeCounts(),
                },
                'recovery': {
                  'action': 'infer_with_fresh_generation',
                  'status': 'passed',
                },
                'execution': {
                  'kind': 'native',
                  'provider': 'native-onnxruntime-1.23.2-cpu',
                  'exitCode': 0,
                  'os': Platform.operatingSystem,
                  'command':
                      'fvm dart test --concurrency=1 test/pool_failure_receipt_test.dart',
                },
              },
            },
          }),
        );
      }
    },
  );
}
