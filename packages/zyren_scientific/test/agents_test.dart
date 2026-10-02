import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_scientific/agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';

import 'scientific_test.dart' show grid, slice;

ScientificSliceView makeView({Scene? scene, ScalarGrid3D? field}) =>
    ScientificSliceView(
      id: 'temperature',
      scene: scene ?? Scene(),
      slice: slice(field ?? grid()),
      coordinateTolerance: 1e-5,
    );

Future<AgentResult> call(
  AgentRegistry registry,
  String tool, {
  Map<String, Object?> arguments = const {},
  int? revision,
  String? key,
  AgentCancellation? cancellation,
}) => registry.call(
  providerId: 'zyren.scientific',
  instanceId: 'temperature',
  tool: tool,
  arguments: arguments,
  expectedRevision: revision,
  idempotencyKey: key,
  cancellation: cancellation,
);

void main() {
  test('disposal removes the owned mesh after external reparenting', () {
    final view = makeView();
    final group = Object3D();
    view.scene.add(group);
    group.add(view.mesh!);
    expect(() => view.checkCurrent(), throwsA(isA<ScientificViewException>()));
    view.dispose();
    expect(group.children, isEmpty);
    expect(group.parent, same(view.scene));
  });
  test(
    'discover schemas, read conformance, missing data and cleanup',
    () async {
      final field = grid(
        values: [for (var i = 0; i < 36; i++) i == 0 ? null : i.toDouble()],
      );
      final view = makeView(field: field);
      final registry = AgentRegistry();
      final binding = registerScientificView(registry, view);
      addTearDown(registry.dispose);
      addTearDown(view.dispose);
      final providers = registry.discover()['providers'] as List;
      expect(providers.length, 1);
      final names = (providers.single['tools'] as List).map(
        (dynamic item) => item['name'],
      );
      expect(
        names,
        containsAll([
          'inspect',
          'sample',
          'field_sample',
          'sample_triangle',
          'set_slice',
          'set_transfer',
        ]),
      );
      final sceneRevision = view.scene.revision;
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: ScientificAgentProvider(view),
          tool: 'inspect',
        ),
        isEmpty,
      );
      expect(view.scene.revision, sceneRevision);
      final inspect = await call(registry, 'inspect');
      expect(inspect.data['time'], isNull);
      expect((inspect.data['dataset'] as Map)['sourceKind'], 'synthetic');
      final missing = await call(
        registry,
        'sample',
        arguments: {'u': 0, 'v': 0},
      );
      expect(missing.status, AgentStatus.empty);
      expect(missing.data['missing'], isTrue);
      expect(missing.data.containsKey('value'), isFalse);
      final sample = await call(
        registry,
        'field_sample',
        arguments: {'x': 1, 'y': 0, 'z': 0},
      );
      expect(sample.status, AgentStatus.ok);
      expect(sample.data['value'], 1);
      expect(
        (await call(registry, 'sample', arguments: {'u': 999, 'v': 0})).status,
        AgentStatus.invalid,
      );
      expect(
        (await call(
          registry,
          'sample',
          arguments: {'u': 0, 'v': 0, 'private': 'x'},
        )).status,
        AgentStatus.invalid,
      );
      expect((await call(registry, 'volume')).status, AgentStatus.unsupported);
      view.dispose();
      expect(registry.discover()['providers'], isEmpty);
      expect(view.scene.children, isEmpty);
      expect((await call(registry, 'inspect')).status, AgentStatus.unavailable);
      binding.dispose();
    },
  );

  test(
    'mutations require host scope and are stale/retry/cancellation safe',
    () async {
      final view = makeView();
      final denied = AgentRegistry();
      final permitted = AgentRegistry(grantedScopes: {'scientific.edit'});
      registerScientificView(denied, view);
      registerScientificView(permitted, view);
      addTearDown(denied.dispose);
      addTearDown(permitted.dispose);
      addTearDown(view.dispose);
      const next = {'axis': 'x', 'index': 1.0};
      expect(
        (await call(
          denied,
          'set_slice',
          arguments: next,
          revision: 0,
          key: 'change',
        )).status,
        AgentStatus.denied,
      );
      expect(
        (await call(permitted, 'set_slice', arguments: next)).status,
        AgentStatus.invalid,
      );
      final cancelled = AgentCancellation()..cancel();
      expect(
        (await call(
          permitted,
          'set_slice',
          arguments: next,
          revision: 0,
          key: 'cancelled',
          cancellation: cancelled,
        )).status,
        AgentStatus.cancelled,
      );
      expect(view.revision, 0);
      final previous = view.mesh;
      final change = await call(
        permitted,
        'set_slice',
        arguments: next,
        revision: 0,
        key: 'change',
      );
      expect(change.status, AgentStatus.ok);
      expect(change.revision, 1);
      expect(change.affectedIds, ['temperature']);
      expect(view.slice.axis, SliceAxis.x);
      expect(previous!.parent, isNull);
      expect(view.scene.children.length, 1);
      final repeat = await call(
        permitted,
        'set_slice',
        arguments: next,
        revision: 0,
        key: 'change',
      );
      expect(repeat.status, AgentStatus.ok);
      expect(view.revision, 1);
      expect(
        (await call(
          permitted,
          'set_slice',
          arguments: next,
          revision: 0,
          key: 'stale',
        )).status,
        AgentStatus.stale,
      );
      expect(
        (await call(
          permitted,
          'set_slice',
          arguments: {'axis': 'z', 'index': 0},
          revision: 0,
          key: 'change',
        )).status,
        AgentStatus.invalid,
      );
      final unchangedMesh = view.mesh;
      expect(
        (await call(
          permitted,
          'set_slice',
          arguments: {'axis': 'x', 'index': 999},
          revision: 1,
          key: 'invalid',
        )).status,
        AgentStatus.invalid,
      );
      expect(view.mesh, same(unchangedMesh));
      expect(view.revision, 1);
      final changed = await call(
        permitted,
        'set_transfer',
        arguments: {
          'minimum': 0,
          'maximum': 40,
          'stops': [
            {
              'position': 0,
              'rgb': [0, 0, 0],
            },
            {
              'position': 1,
              'rgb': [1, 1, 1],
            },
          ],
        },
        revision: 1,
        key: 'transfer',
      );
      expect(changed.status, AgentStatus.ok);
      expect(view.revision, 2);
      expect(view.slice.transfer.maximum, 40);
      expect(view.slice.transfer.map(20), const Color3(.5, .5, .5));
      view.scene.remove(view.mesh!);
      expect((await call(permitted, 'inspect')).status, AgentStatus.stale);
    },
  );

  test(
    'domain picking samples affine values and rejects old hit snapshots',
    () {
      final view = makeView();
      addTearDown(view.dispose);
      final hit = Raycaster()
          .capture(
            view.scene,
            Ray(const Vec3(.25, .5, 5), const Vec3(0, 0, -1)),
          )
          .intersectFirst()!;
      final context = view.inspectHit(hit, expectedRevision: 0);
      expect(context['value'], closeTo(14.5, 1e-12));
      expect(context['pixelVisibility'], 'unknown');
      expect(context['datasetId'], 'fixture:affine:v1');
      view.setSlice(axis: SliceAxis.z, index: 1, expectedRevision: 0);
      expect(
        () => view.inspectHit(hit, expectedRevision: 1),
        throwsA(isA<ScientificViewException>()),
      );
      final revision = view.revision;
      view.mesh!.position = Vec3.zero;
      expect(() => view.describe(), throwsA(isA<ScientificViewException>()));
      expect(view.revision, revision);
    },
  );

  test(
    'shared viewport pick preserves context and joins a scientific scalar',
    () async {
      final view = makeView();
      final registry = AgentRegistry(grantedScopes: {'scientific.edit'});
      registerScientificView(registry, view);
      addTearDown(view.dispose);
      addTearDown(registry.dispose);
      final camera = OrthographicCamera(
        position: const Vec3(1, 1.5, 5),
        target: const Vec3(1, 1.5, 0),
        left: -1,
        right: 1,
        bottom: -1.5,
        top: 1.5,
      );
      final scientific = ScientificAgentProvider(view);
      registry.register(
        AgentViewportProvider(
          sceneId: 'scene-fixture',
          documentId: 'document-fixture',
          instanceId: 'main-view',
          scene: view.scene,
          camera: () => camera,
          viewport: () => const ViewportMetrics(200, 300, devicePixelRatio: 2),
          metadata: scientific.metadata,
          units: 'm',
        ),
      );
      final hit = await registry.call(
        providerId: 'zyren.viewport',
        instanceId: 'main-view',
        tool: 'pick',
        arguments: {'x': 100, 'y': 150},
        expectedRevision: view.scene.revision,
      );
      expect(hit.status, AgentStatus.ok);
      expect(hit.data['documentId'], 'document-fixture');
      expect(hit.data['viewportId'], 'main-view');
      expect(hit.data['devicePixelRatio'], 2);
      expect(hit.data['presentedFrame'], isNull);
      final picked = (hit.data['hits'] as List).first as Map;
      final object = picked['object'] as Map;
      final metadata = object['metadata'] as Map;
      expect(metadata['sourceId'], 'fixture:affine:v1');
      expect((metadata['properties'] as Map)['scientific'], isA<Map>());
      final weights = picked['barycentric'] as List;
      final joined = await call(
        registry,
        'sample_triangle',
        revision: 0,
        arguments: {
          'runtimeObjectId': object['runtimeId'],
          'sceneRevision': hit.data['sceneRevision'],
          'triangleIndex': picked['triangleIndex'],
          'barycentric': weights,
        },
      );
      expect(joined.status, AgentStatus.ok);
      expect(joined.data['value'], closeTo(19, 1e-12));
      expect(joined.data['pixelVisibility'], 'unknown');
      expect(joined.data['method'], 'caller-supplied-triangle-barycentrics');
      final bad = await call(
        registry,
        'sample_triangle',
        arguments: {
          'runtimeObjectId': object['runtimeId'],
          'sceneRevision': view.scene.revision,
          'triangleIndex': picked['triangleIndex'],
          'barycentric': [.2, .2, .2],
        },
      );
      expect(bad.status, AgentStatus.invalid);
      await call(
        registry,
        'set_slice',
        revision: 0,
        key: 'next',
        arguments: {'axis': 'z', 'index': 1},
      );
      expect(
        (await call(
          registry,
          'sample_triangle',
          arguments: {
            'runtimeObjectId': object['runtimeId'],
            'sceneRevision': hit.data['sceneRevision'],
            'triangleIndex': picked['triangleIndex'],
            'barycentric': weights,
          },
        )).status,
        AgentStatus.stale,
      );
    },
  );
}
