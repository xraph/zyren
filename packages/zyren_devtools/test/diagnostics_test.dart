import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:test/test.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  late Scene scene;
  late PerspectiveCamera camera;
  late SceneDevtoolsPlugin inspector;
  late SceneDiagnostics diagnostics;
  late SceneEngine engine;
  setUp(() async {
    scene = Scene();
    camera = PerspectiveCamera();
    inspector = SceneDevtoolsPlugin(historyLimit: 2);
    diagnostics = SceneDiagnostics(inspector, issueLimit: 2);
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [inspector],
    );
  });
  tearDown(() async => engine.dispose());

  test('transparent scene backgrounds remain null in inspection', () {
    scene.background = null;
    final root = diagnostics.call('inspect_scene', {})['root'] as Map;
    expect(root['backgroundLinear'], isNull);
  });

  test(
    'pages detect intervening edits and IDs cannot resolve removed objects',
    () {
      final first = scene.add(Group(name: 'parent'));
      first.add(Mesh(BoxGeometry(), UnlitMaterial(), name: 'cube'));
      final page = diagnostics.call('inspect_scene', {'limit': 1});
      expect(page['schemaVersion'], 1);
      expect(page['nextOffset'], 1);
      final nodes = page['nodes'] as List;
      final id = (nodes.single as Map)['id'];
      final revision = page['revision'];
      expect(
        diagnostics.call('inspect_scene', {
          'offset': 1,
          'expectedRevision': revision,
        })['nextOffset'],
        isNull,
      );
      first.position = const Vec3(10, 0, 0);
      expect(
        () => diagnostics.call('inspect_scene', {'expectedRevision': revision}),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'staleRevision',
          ),
        ),
      );
      scene.remove(first);
      expect(
        () => diagnostics.call('inspect_object', {'id': id}),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'objectNotFound',
          ),
        ),
      );
    },
  );

  test('doctor explains inherited hiding and conservative clip exclusion', () {
    final parent = scene.add(Group()..visible = false);
    final mesh = parent.add(Mesh(BoxGeometry(), UnlitMaterial()));
    Map<String, Object?> doctor() =>
        diagnostics.call('diagnose_scene', {'aspect': 1});
    expect(
      (doctor()['findings'] as List).map((e) => e['code']),
      contains('allMeshesHidden'),
    );
    parent.visible = true;
    parent.position = const Vec3(100, 0, 0);
    expect(
      (doctor()['findings'] as List).map((e) => e['code']),
      contains('outsideClipVolume'),
    );
    parent.position = Vec3.zero;
    mesh.scale = const Vec3(100, 100, 100);
    expect(
      (doctor()['findings'] as List).map((e) => e['code']),
      isNot(contains('outsideClipVolume')),
    );
    expect(doctor()['pixelVisibility'], 'unverified');
  });

  test('doctor handles camera behind objects and scene root transforms', () {
    scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    scene.position = const Vec3(0, 0, 10);
    final report = diagnostics.call('diagnose_scene', {'aspect': 1});
    expect(
      (report['findings'] as List).map((e) => e['code']),
      contains('outsideClipVolume'),
    );
    scene.position = Vec3.zero;
    camera.target = camera.position;
    expect(
      (diagnostics.call('diagnose_scene', {'aspect': 1})['findings'] as List)
          .map((e) => e['code']),
      contains('invalidCamera'),
    );
  });

  test(
    'absent viewport and measurements stay unknown, bounded reports encode',
    () async {
      expect(
        (diagnostics.call('diagnose_scene')['findings'] as List).map(
          (e) => e['code'],
        ),
        contains('viewportUnknown'),
      );
      for (var i = 0; i < 3; i++) {
        await engine.render(
          elapsed: Duration(milliseconds: i * 20),
          width: 8,
          height: 8,
        );
        diagnostics.recordIssue(
          SceneIssue(
            code: 'failure$i',
            message: 'Failed',
            operation: 'render',
            cause: Object(),
          ),
        );
      }
      final stats = diagnostics.call('capture_frame_stats');
      final frames = stats['frames'] as List;
      expect(frames.length, 2);
      expect(frames.last['gpuTimeUs'], isNull);
      expect(frames.last['residentBytes'], isNull);
      expect(
        (diagnostics.call('get_scene_issues')['issues'] as List).map(
          (e) => e['code'],
        ),
        ['failure1', 'failure2'],
      );
      expect(
        () => jsonEncode(diagnostics.call('export_report')),
        returnsNormally,
      );
    },
  );

  test(
    'orthographic and camera-relative bounds work at large world coordinates',
    () {
      scene.position = const Vec3(6378137, 0, 0);
      scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      engine.camera = OrthographicCamera(
        position: const Vec3(6378137, 0, 5),
        target: const Vec3(6378137, 0, 0),
      );
      final inside = diagnostics.call('diagnose_scene', {'aspect': 2});
      expect(
        (inside['findings'] as List).map((e) => e['code']),
        isNot(contains('outsideClipVolume')),
      );
      scene.position = const Vec3(6378147, 0, 0);
      expect(
        (diagnostics.call('diagnose_scene', {'aspect': 2})['findings'] as List)
            .map((e) => e['code']),
        contains('outsideClipVolume'),
      );
    },
  );

  test('oversized scenes fail instead of diagnosing a partial traversal', () {
    scene.batch(() {
      for (var i = 0; i < 10001; i++) {
        scene.add(Group());
      }
    });
    expect(
      () => diagnostics.call('diagnose_scene', {'aspect': 1}),
      throwsA(
        isA<DiagnosticException>().having(
          (e) => e.code,
          'code',
          'sceneTooLarge',
        ),
      ),
    );
  });

  test('returned issues cannot overwrite retained evidence', () {
    diagnostics.recordIssue(
      SceneIssue(
        code: 'deviceLost',
        message: 'Device lost',
        operation: 'render',
        requiredFeatures: {RenderFeature.indexedMeshes},
      ),
    );
    final issue =
        (diagnostics.call('get_scene_issues')['issues'] as List).single as Map;
    issue['code'] = 'overwritten';
    (issue['requiredFeatures'] as List).clear();
    final saved =
        (diagnostics.call('get_scene_issues')['issues'] as List).single;
    expect(saved['code'], 'deviceLost');
    expect(saved['requiredFeatures'], ['indexedMeshes']);
  });

  test(
    'startup issues remain readable while no renderer is attached',
    () async {
      await engine.dispose();
      diagnostics.recordIssue(
        SceneIssue(
          code: 'backendUnavailable',
          message: 'Backend unavailable',
          operation: 'initialize',
        ),
      );
      final result = diagnostics.call('get_scene_issues');
      expect(result['attached'], false);
      expect((result['issues'] as List).single['code'], 'backendUnavailable');
    },
  );

  test(
    'invalid input fails explicitly and detached state cannot serve stale data',
    () async {
      for (final args in [
        {'limit': 0},
        {'limit': 1001},
        {'offset': -1},
        {'unknown': true},
      ]) {
        expect(
          () => diagnostics.call('inspect_scene', args),
          throwsA(isA<DiagnosticException>()),
        );
      }
      expect(
        () => diagnostics.call('diagnose_scene', {'aspect': double.nan}),
        throwsA(isA<DiagnosticException>()),
      );
      await engine.dispose();
      expect(
        () => diagnostics.call('inspect_scene'),
        throwsA(
          isA<DiagnosticException>().having(
            (e) => e.code,
            'code',
            'notAttached',
          ),
        ),
      );
    },
  );
}
