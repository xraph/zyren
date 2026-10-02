import 'package:zyren/zyren.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:test/test.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'snapshots keep stable IDs and copied hierarchy after scene edits',
    () async {
      final scene = Scene();
      final parent = scene.add(Group(name: 'Assembly')..visible = false);
      final mesh = parent.add(
        Mesh(BoxGeometry(), UnlitMaterial(), name: 'Part'),
      );
      final inspector = SceneDevtoolsPlugin();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [inspector],
      );
      final before = inspector.snapshot();
      expect(before.nodes.length, 2);
      final part = before.nodes.last;
      expect(part.parentId, before.nodes.first.id);
      expect(part.depth, 1);
      expect(part.triangles, 12);
      expect(part.effectivelyVisible, isFalse);
      mesh.position = const Vec3(4, 0, 0);
      parent.visible = true;
      final after = inspector.snapshot();
      expect(after.nodes.last.id, part.id);
      expect(after.nodes.last.position, const Vec3(4, 0, 0));
      expect(after.nodes.last.effectivelyVisible, isTrue);
      expect(part.position, Vec3.zero);
      expect(inspector.objectFor(part.id), same(mesh));
      parent.remove(mesh);
      expect(inspector.objectFor(part.id), isNull);
      await engine.dispose();
      expect(inspector.isAttached, isFalse);
      expect(() => inspector.snapshot(), throwsStateError);
    },
  );

  test(
    'frame history is bounded and absent measurements stay unavailable',
    () async {
      final inspector = SceneDevtoolsPlugin(historyLimit: 2);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [inspector],
      );
      for (var i = 0; i < 4; i++) {
        await engine.render(
          elapsed: Duration(milliseconds: i * 250),
          width: 8,
          height: 8,
        );
      }
      expect(inspector.frames.length, 2);
      expect(inspector.frames.map((f) => f.frameId), [2, 3]);
      expect(inspector.frames.last.gpuTime, isNull);
      expect(inspector.frames.last.residentBytes, isNull);
      final saved = inspector.frames;
      await engine.render(
        elapsed: const Duration(seconds: 2),
        width: 8,
        height: 8,
      );
      expect(saved.map((f) => f.frameId), [2, 3]);
      await engine.dispose();
      expect(inspector.frames, isEmpty);
    },
  );

  test('invalid history budgets fail before attachment', () {
    expect(() => SceneDevtoolsPlugin(historyLimit: 0), throwsArgumentError);
  });
}
