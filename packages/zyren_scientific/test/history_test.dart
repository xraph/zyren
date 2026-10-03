import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_scientific/agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'scientific_test.dart' show grid, transfer, source, slice;

ScientificFieldView field({
  int limit = 32,
  int bytes = 32 * 1024 * 1024,
  TemporalScalarSource? temporal,
}) => ScientificFieldView(
  id: 'history',
  scene: Scene(),
  grid: grid(x: 3, y: 3, z: 3),
  transfer: transfer(),
  coordinateTolerance: 1e-5,
  historyLimit: limit,
  historyByteLimit: bytes,
  temporal: temporal,
);

void main() {
  test(
    'history restores immutable temporal values and all field settings',
    () async {
      var loads = 0;
      final temporal = TemporalScalarSource(
        source: source,
        timeUnit: ScientificUnit(quantity: 'time', symbol: 's'),
        frames: [
          for (var i = 0; i < 2; i++)
            ScientificFrameKey(id: 'f$i', version: 'v1', time: i.toDouble()),
        ],
        load: (key, token) async {
          loads++;
          return grid(x: 3, y: 3, z: 3, values: List.filled(27, key.time * 20));
        },
      );
      final view = field(temporal: temporal);
      await view.configure(expectedRevision: 0, sliceIndex: .5);
      expect(view.canUndo, isFalse);
      final initial = view.grid;
      await view.configure(
        expectedRevision: view.revision,
        time: .5,
        threshold: 5,
        sliceIndex: 1,
        seed: const Vec3(.1, .2, .3),
        vectorScale: .4,
        volumeOpacity: .7,
        volumeSampleDistance: .08,
        transfer: transfer(),
      );
      final restored = view.grid;
      final state = view.describe();
      expect(restored.valueAt(0, 0, 0), 10);
      await temporal.dispose();
      expect(await view.undo(expectedRevision: view.revision), isTrue);
      expect(view.grid, same(initial));
      expect(view.time, isNull);
      expect(await view.redo(expectedRevision: view.revision), isTrue);
      expect(view.grid, same(restored));
      expect(view.time!.frames.map((f) => f.version), ['v1', 'v1']);
      for (final key in [
        'threshold',
        'sliceIndex',
        'seed',
        'vectorScale',
        'volumeOpacity',
        'volumeSampleDistance',
        'transferMinimum',
        'time',
      ]) {
        expect(view.describe()[key], state[key], reason: key);
      }
      await view.configure(expectedRevision: view.revision, clearTime: true);
      expect(view.grid, same(initial));
      expect(view.time, isNull);
      await view.undo(expectedRevision: view.revision);
      expect(view.grid, same(restored));
      expect(view.time!.time, .5);
      expect(loads, 2);
      await view.dispose();
      expect(view.history['retainedPayloadBytes'], 0);
      expect(view.canUndo, isFalse);
    },
  );

  test(
    'failed and cancelled edits preserve redo; new edits invalidate it',
    () async {
      final view = field();
      await view.configure(expectedRevision: 0);
      await view.configure(expectedRevision: view.revision, sliceIndex: 1);
      await view.undo(expectedRevision: view.revision);
      final revision = view.revision, mesh = view.mesh, history = view.history;
      await expectLater(
        view.configure(expectedRevision: revision, sliceIndex: -1),
        throwsArgumentError,
      );
      await expectLater(
        view.redo(
          expectedRevision: revision,
          cancellation: ScientificCancellation(
            isCancellationRequested: () => true,
          ),
        ),
        throwsA(isA<ScientificCancelled>()),
      );
      expect(view.history, history);
      expect(view.revision, revision);
      expect(view.mesh, same(mesh));
      await view.configure(expectedRevision: revision, threshold: 25);
      expect(view.canRedo, isFalse);
      view.mesh!.position = const Vec3(3, 0, 0);
      await expectLater(
        view.undo(expectedRevision: view.revision),
        throwsA(isA<ScientificViewException>()),
      );
      await view.dispose();
    },
  );

  test(
    'history obeys count and payload ceilings and serializes revisions',
    () async {
      final view = field(limit: 2);
      await view.configure(expectedRevision: 0);
      for (var i = 1; i <= 4; i++) {
        await view.configure(
          expectedRevision: view.revision,
          threshold: i.toDouble(),
        );
      }
      expect(view.history['undoCount'], 2);
      final revision = view.revision;
      final undo = view.undo(expectedRevision: revision);
      final collision = expectLater(
        view.redo(expectedRevision: revision),
        throwsA(isA<ScientificViewException>()),
      );
      await undo;
      await collision;
      expect(view.describe()['threshold'], 3);
      await view.undo(expectedRevision: view.revision);
      expect(view.describe()['threshold'], 2);
      expect(await view.undo(expectedRevision: view.revision), isFalse);
      await view.clearHistory(expectedRevision: view.revision);
      expect(view.history['retainedPayloadBytes'], 0);
      await view.dispose();
      final bounded = field(bytes: 1);
      await bounded.configure(expectedRevision: 0);
      await bounded.configure(expectedRevision: 1, threshold: 10);
      expect(bounded.canUndo, isFalse);
      expect(bounded.history['retainedPayloadBytes'], 0);
      await bounded.dispose();
      expect(() => field(limit: 257), throwsArgumentError);
    },
  );

  test(
    'field history tools enforce scope, revision, cancellation and retry',
    () async {
      final view = field();
      final denied = AgentRegistry(),
          allowed = AgentRegistry(grantedScopes: {'scientific.edit'});
      registerScientificField(denied, view);
      registerScientificField(allowed, view);
      await view.configure(expectedRevision: 0);
      await view.configure(expectedRevision: 1, threshold: 30);
      Future<AgentResult> call(
        AgentRegistry registry,
        String tool, {
        int? revision,
        String? key,
        AgentCancellation? cancellation,
      }) => registry.call(
        providerId: 'zyren.scientific.field',
        instanceId: view.id,
        tool: tool,
        expectedRevision: revision ?? view.revision,
        idempotencyKey: key,
        cancellation: cancellation,
      );
      expect(
        (await call(denied, 'undo', key: 'denied')).status,
        AgentStatus.denied,
      );
      expect((await call(allowed, 'undo')).status, AgentStatus.invalid);
      final revision = view.revision;
      final first = await call(allowed, 'undo', key: 'undo');
      expect(first.status, AgentStatus.ok);
      expect(
        (await call(allowed, 'undo', revision: revision, key: 'undo')).revision,
        first.revision,
      );
      expect(view.revision, revision + 1);
      expect(
        (await call(allowed, 'redo', revision: revision, key: 'stale')).status,
        AgentStatus.stale,
      );
      final token = AgentCancellation()..cancel();
      expect(
        (await call(
          allowed,
          'redo',
          key: 'cancelled',
          cancellation: token,
        )).status,
        AgentStatus.cancelled,
      );
      expect((await call(allowed, 'redo', key: 'redo')).status, AgentStatus.ok);
      expect((await call(allowed, 'history')).data['undoCount'], 1);
      expect(
        (await call(allowed, 'clear_history', key: 'clear')).status,
        AgentStatus.ok,
      );
      expect(
        (await call(allowed, 'undo', key: 'empty')).status,
        AgentStatus.empty,
      );
      await view.dispose();
      expect(allowed.discover()['providers'], isEmpty);
      allowed.dispose();
      denied.dispose();
    },
  );

  test(
    'slice history restores axis, index and transfer through shared tools',
    () async {
      final view = ScientificSliceView(
        id: 'slice',
        scene: Scene(),
        slice: slice(grid()),
        coordinateTolerance: 1e-5,
        historyLimit: 2,
      );
      final original = view.slice;
      view.setSlice(axis: SliceAxis.x, index: .5, expectedRevision: 0);
      view.setTransfer(transfer(), expectedRevision: 1);
      final registry = AgentRegistry(grantedScopes: {'scientific.edit'});
      registerScientificView(registry, view);
      Future<AgentResult> call(String name) => registry.call(
        providerId: 'zyren.scientific',
        instanceId: view.id,
        tool: name,
        expectedRevision: view.revision,
        idempotencyKey: '$name-${view.revision}',
      );
      expect((await call('undo')).status, AgentStatus.ok);
      expect((await call('undo')).status, AgentStatus.ok);
      expect(view.slice.axis, original.axis);
      expect(view.slice.index, original.index);
      expect(view.slice.transfer, same(original.transfer));
      expect((await call('redo')).status, AgentStatus.ok);
      expect(view.slice.axis, SliceAxis.x);
      view.mesh!.position = const Vec3(1, 0, 0);
      expect((await call('undo')).status, AgentStatus.stale);
      view.dispose();
      registry.dispose();
      expect(view.history['retainedPayloadBytes'], 0);
    },
  );
}
