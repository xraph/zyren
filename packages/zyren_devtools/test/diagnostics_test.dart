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
