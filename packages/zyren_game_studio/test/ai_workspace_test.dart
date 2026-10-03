import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_game_ai/test/policy_test.dart' show PolicyFixture;
import '../../zyren_ml/test/support/delayed_worker.dart';

void main() {
  test(
    'AI authoring composes mutable codec registration before frozen catalog',
    () {
      final authoring = createGameAiDevelopmentAuthoring();
      expect(
        authoring.descriptors.keys,
        containsAll(['game.ai', 'game.character-rig', 'game.character']),
      );
      final definition = authoring.registry.construct(
        authoring.descriptors['game.ai']!.create(),
      );
      expect(definition, isA<GameAiAuthoringDefinition>());
      expect(
        () => authoring.registry.registerComponent(GameAiAuthoringCodec()),
        throwsStateError,
      );
    },
  );
  test(
    'import preserves active model; schema order and stale evaluation prevent activation',
    () async {
      final fixture = PolicyFixture();
      final manifest = fakeManifest();
      final worker = DelayedWorker();
      final cache = MlModelCache(
        resolver: (_) async => Uint8List.fromList([7]),
        worker: worker,
      );
      addTearDown(cache.close);
      final contract = fixture.contract(manifest, ActionDecoder.character());
      final importer = ModelImport(
        cache: cache,
        observation: contract.observation,
        action: contract.decoder.spec,
      );
      var active = 'previous';
      var revision = 2;
      final workspace = GameAiWorkspace()
        ..activeModelHash = active
        ..importer = importer;
      addTearDown(() async {
        await workspace.close();
        workspace.dispose();
      });
      workspace.activation = ModelActivation(
        currentRevision: () => revision,
        apply: (value, expected) {
          expect(expected, revision);
          active = value.model.sha256;
        },
      );
      await workspace.importModel(contract);
      expect(workspace.activeModelHash, 'previous');
      expect(workspace.candidate!.compatible, isTrue);
      await expectLater(workspace.activate(), throwsStateError);
      final reordered = ObservationSpec(
        id: 'different-order',
        fields: contract.observation.fields.reversed.toList(),
        latencyTicks: 2,
      );
      final incompatible = await ModelImport(
        cache: cache,
        observation: reordered,
        action: contract.decoder.spec,
      ).validate(contract);
      expect(incompatible.compatible, isFalse);
      final stale = TrainingEvaluation(
        modelHash: 'f' * 64,
        observationHash: contract.observation.hash,
        actionHash: contract.decoder.spec.hash,
        receiptHash: 'e' * 64,
        accepted: true,
        cases: [
          {'id': 'case'},
        ],
      );
      await workspace.importModel(contract, evaluation: stale);
      expect(workspace.candidate!.accepted, isFalse);
      final current = TrainingEvaluation(
        modelHash: manifest.sha256,
        observationHash: contract.observation.hash,
        actionHash: contract.decoder.spec.hash,
        receiptHash: 'e' * 64,
        accepted: true,
        cases: [
          {'id': 'case'},
        ],
      );
      await workspace.importModel(contract, evaluation: current);
      await workspace.activate();
      expect(active, manifest.sha256);
      revision++;
      await expectLater(
        workspace.activation!.commit(workspace.candidate!, expectedRevision: 2),
        throwsStateError,
      );
    },
  );
  test(
    'cancelled model preparation releases lease and preserves selection',
    () async {
      final fixture = PolicyFixture();
      final token = MlCancellationToken();
      final gate = Completer<void>();
      final cache = MlModelCache(
        worker: DelayedWorker(),
        resolver: (_) async {
          await gate.future;
          return Uint8List.fromList([7]);
        },
      );
      addTearDown(cache.close);
      final contract = fixture.contract(
        fakeManifest(),
        ActionDecoder.character(),
      );
      final importer = ModelImport(
        cache: cache,
        observation: contract.observation,
        action: contract.decoder.spec,
      );
      final pending = importer.validate(contract, cancellation: token);
      final assertion = expectLater(
        pending,
        throwsA(isA<ModelImportCancelled>()),
      );
      token.cancel();
      gate.complete();
      await assertion;
      expect(cache.diagnostics.leaseReferences, 0);
    },
  );
  test(
    'permission revocation during model preparation leaves candidate unchanged',
    () async {
      final f = PolicyFixture(), gate = Completer<void>();
      final cache = MlModelCache(
        worker: DelayedWorker(),
        resolver: (_) async {
          await gate.future;
          return Uint8List.fromList([7]);
        },
      );
      addTearDown(cache.close);
      final contract = f.contract(fakeManifest(), ActionDecoder.character());
      final workspace = GameAiWorkspace()
        ..importer = ModelImport(
          cache: cache,
          observation: contract.observation,
          action: contract.decoder.spec,
        );
      addTearDown(workspace.dispose);
      final pending = workspace.importModel(contract);
      final rejected = expectLater(
        pending,
        throwsA(isA<ModelImportCancelled>()),
      );
      workspace.permitted = false;
      gate.complete();
      await rejected;
      expect(workspace.candidate, isNull);
      expect(workspace.models, isEmpty);
      expect(cache.diagnostics.leaseReferences, 0);
    },
  );
  testWidgets(
    'scripted actor chooser uses permitted callback without a policy group',
    (tester) async {
      final entities = GameEntityTable();
      final first = entities.spawn('script-first'),
          second = entities.spawn('script-second');
      final workspace = GameAiWorkspace()
        ..availableActors = (() => [first, second])
        ..inspectActor = ((actor) => {
          'brain': 'scripted',
          'observedTick': actor == first ? 3 : 7,
        })
        ..selectedActor = first;
      addTearDown(workspace.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GameBrainInspector(workspace: workspace)),
        ),
      );
      expect(find.text('observedTick: 3'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<GameEntityHandle>));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('script-second · generation ${second.generation}').last,
      );
      await tester.pumpAndSettle();
      expect(workspace.selectedActor, second);
      expect(find.text('observedTick: 7'), findsOneWidget);
      entities.despawn(second);
      workspace.availableActors = () => [first];
      workspace.inspectActor = (_) => null;
      workspace.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Choose an NPC actor'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compact AI panels distinguish denied and unavailable at widths and large text',
    (tester) async {
      final workspace = GameAiWorkspace();
      try {
        for (final width in [1440.0, 1024.0, 396.0, 328.0]) {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          for (final dark in [false, true]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 900),
                    textScaler: const TextScaler.linear(2),
                  ),
                  child: Scaffold(
                    body: GameTrainingPanel(workspace: workspace),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text('Local worker unavailable'), findsOneWidget);
            expect(find.text('No model imported'), findsOneWidget);
            final button = tester.widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Start local run'),
            );
            expect(button.onPressed, isNull);
            expect(tester.takeException(), isNull);
          }
        }
        workspace.permitted = false;
        workspace.refresh();
        await tester.pumpAndSettle();
        expect(find.text('Training access denied'), findsOneWidget);
        expect(find.byType(ZeroState), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.view.reset();
        await workspace.close();
        workspace.dispose();
      }
    },
  );
}
