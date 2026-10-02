import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'section sessions restore prior planes and preserve external edits',
    () async {
      final initial = ClippingPlane(normal: const Vec3(1, 0, 0));
      final cut = ClippingPlane(normal: const Vec3(0, 1, 0));
      final external = ClippingPlane(normal: const Vec3(0, 0, 1));
      final scene = Scene()..clippingPlanes = [initial];
      final sections = SceneSectionPlugin();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [sections],
      );
      try {
        sections.setPlanes([cut]);
        expect(sections.isActive, isTrue);
        expect(scene.clippingPlanes, [cut]);
        sections.clear();
        expect(scene.clippingPlanes, [initial]);
        sections.setPlanes([cut]);
        expect(
          () => sections.setPlanes(List.filled(7, cut)),
          throwsArgumentError,
        );
        expect(sections.isActive, isTrue);
        scene.clippingPlanes = [external];
        expect(sections.isActive, isFalse);
        sections.clear();
        expect(scene.clippingPlanes, [external]);
        sections.setPlanes([cut]);
        sections.setPlanes([cut.flipped]);
      } finally {
        await engine.dispose();
      }
      expect(scene.clippingPlanes, [external]);
      expect(() => sections.setPlanes([cut]), throwsStateError);
    },
  );

  test('detach does not overwrite an external section edit', () async {
    final scene = Scene();
    final sections = SceneSectionPlugin();
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [sections],
    );
    sections.setPlanes([ClippingPlane(normal: const Vec3(1, 0, 0))]);
    scene.clippingPlanes = [];
    await engine.dispose();
    expect(scene.clippingPlanes, isEmpty);
  });
}
