import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'package:zyren_scientific/agents.dart';
import 'scientific_test.dart' show grid, transfer, source;
import 'vectors_test.dart' show vectorField;

void main() {
  test(
    'shared field tools preserve atomic state, identity, retry and cancellation',
    () async {
      final scene = Scene(),
          temporal = TemporalScalarSource(
            source: source,
            timeUnit: ScientificUnit(quantity: 'time', symbol: 's'),
            frames: [
              for (var i = 0; i < 2; i++)
                ScientificFrameKey(id: 'f$i', version: '1', time: i.toDouble()),
            ],
            load: (k, c) async => grid(
              x: 3,
              y: 3,
              z: 3,
              values: List.filled(27, 10 + k.time * 20),
            ),
          );
      final view = ScientificFieldView(
        id: 'field',
        scene: scene,
        grid: grid(x: 3, y: 3, z: 3),
        transfer: transfer(),
        coordinateTolerance: 1e-5,
        vectors: vectorField((p) => const Vec3(1, 0, 0)),
        temporal: temporal,
      );
      final denied = AgentRegistry(),
          registry = AgentRegistry(grantedScopes: {'scientific.edit'});
      registerScientificField(denied, view);
      registerScientificField(registry, view);
      Future<AgentResult> call(
        String tool,
        Map<String, Object?> args, {
        int? revision,
        String? key,
        AgentCancellation? token,
      }) => registry.call(
        providerId: 'zyren.scientific.field',
        instanceId: 'field',
        tool: tool,
        arguments: args,
        expectedRevision: revision ?? view.revision,
        idempotencyKey: key ?? 'r${view.revision}-$tool',
        cancellation: token,
      );
      expect(
        (await denied.call(
          providerId: 'zyren.scientific.field',
          instanceId: 'field',
          tool: 'set_representation',
          arguments: {'representation': 'isosurface'},
          expectedRevision: 0,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      final result = await call('set_representation', {
        'representation': 'isosurface',
      }, key: 'iso');
      expect(result.status, AgentStatus.ok);
      final mesh = view.mesh;
      final hit = Raycaster()
          .captureFromCamera(
            scene,
            OrthographicCamera(
              position: const Vec3(1, 1, 5),
              target: const Vec3(1, 1, 0),
            ),
            const ViewportPoint(50, 50),
            logicalWidth: 100,
            logicalHeight: 100,
          )
          .intersectFirst()!;
      final joined = await call('sample_triangle', {
        'runtimeObjectId': hit.object.id,
        'sceneRevision': hit.sceneRevision,
        'triangleIndex': hit.triangleIndex,
        'barycentric': hit.barycentric.storage,
      });
      expect(joined.status, AgentStatus.ok);
      expect(joined.data['sourceCell'], isNotNull);
      expect(joined.data['isosurfaceValue'], 21.5);

      expect(
        (await call(
          'set_representation',
          {'representation': 'isosurface'},
          revision: 0,
          key: 'iso',
        )).status,
        AgentStatus.ok,
      );
      expect(view.revision, 1);
      expect(
        (await call('set_parameters', {
          'sliceIndex': -1,
          'volumeOpacity': 2,
        })).status,
        AgentStatus.invalid,
      );
      expect(view.mesh, mesh);
      expect(view.revision, 1);
      final token = AgentCancellation();
      final future = call(
        'set_representation',
        {'representation': 'isosurface'},
        token: token,
        key: 'cancel',
      );
      token.cancel();
      expect((await future).status, AgentStatus.cancelled);
      expect(view.mesh, mesh);
      expect(view.revision, 1);
      expect((await call('seek', {'time': .5})).status, AgentStatus.ok);
      expect(view.time!.time, .5);
      final sampled = await call('sample_position', {
        'position': [.5, .5, .05],
      });
      expect(sampled.data['value'], 20);
      expect(sampled.data['vector'], [1, 0, 0]);
      for (final mode in ['slice', 'vectors', 'streamline']) {
        expect(
          (await call('set_representation', {'representation': mode})).status,
          AgentStatus.ok,
        );
      }
      final before = view.revision;
      expect(
        (await call('set_representation', {'representation': 'volume'})).status,
        AgentStatus.unavailable,
      );
      expect(view.revision, before);
      await view.dispose();
      await temporal.dispose();
      expect(scene.children, isEmpty);
      expect((await call('inspect', {})).status, AgentStatus.unavailable);
      registry.dispose();
      denied.dispose();
    },
  );
  test(
    'concurrent commands cannot overwrite newer state or disposed views',
    () async {
      final view = ScientificFieldView(
        id: 'race',
        scene: Scene(),
        grid: grid(x: 20, y: 20, z: 20),
        transfer: transfer(),
        coordinateTolerance: 1e-5,
      );
      final a = view.configure(
        expectedRevision: 0,
        representation: ScientificRepresentation.isosurface,
        threshold: 50,
      );
      final b = view.configure(
        expectedRevision: 0,
        representation: ScientificRepresentation.slice,
      );
      final stale = expectLater(b, throwsA(isA<ScientificViewException>()));
      await a;
      await stale;
      expect(view.revision, 1);
      final work = view.configure(
        expectedRevision: 1,
        representation: ScientificRepresentation.isosurface,
      );
      final cancelled = expectLater(
        work,
        throwsA(
          anyOf(isA<ScientificCancelled>(), isA<ScientificViewException>()),
        ),
      );
      await view.dispose();
      await cancelled;
      expect(view.scene.children, isEmpty);
    },
  );
}
