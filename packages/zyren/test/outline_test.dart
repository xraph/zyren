import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/fakes.dart';

void main() {
  test(
    'engines report unsupported outlines before invoking a renderer',
    () async {
      final scene = Scene();
      final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final renderer = TestRenderer([]);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => renderer,
      );
      try {
        scene.outline = SceneOutline(objects: [mesh]);
        await expectLater(
          engine.render(elapsed: Duration.zero, width: 8, height: 8),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.requiredFeatures,
              'features',
              contains(RenderFeature.selectionOutlines),
            ),
          ),
        );
        expect(renderer.renders, 0);
        scene.outline = null;
        await engine.render(elapsed: Duration.zero, width: 8, height: 8);
        expect(renderer.renders, 1);
      } finally {
        await engine.dispose();
      }
    },
  );
  test(
    'outline snapshots inherit selection, exclude helpers and freeze style',
    () {
      final scene = Scene();
      final group = scene.add(Group());
      final mesh = group.add(Mesh(BoxGeometry(), UnlitMaterial()));
      group.add(Mesh(BoxGeometry(), UnlitMaterial())..outlineEnabled = false);
      final objects = <Object3D>[group];
      scene.outline = SceneOutline(objects: objects, width: 3);
      objects.clear();
      expect(scene.outline!.objects, [group]);
      expect(() => scene.outline!.objects.clear(), throwsUnsupportedError);
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(16, 16),
      );
      final captured = capture();
      expect(captured.scene.drawCalls, 4);
      expect(() => captured.toNativePacket(), throwsUnsupportedError);
      final encoder = ScenePacketEncoder(viewId: 1);
      final first = encoder.encode(captured);
      expect(ByteData.sublistView(first.bytes).getUint32(4, Endian.little), 30);
      encoder.accept(first);
      mesh.outlineEnabled = false;
      expect(captured.scene.drawCalls, 4);
      expect(capture().scene.drawCalls, 2);
      mesh.outlineEnabled = true;
      scene.outline = SceneOutline(
        objects: [mesh],
        color: Color3.hex(0xff0000),
      );
      final sameSelection = encoder.encode(capture());
      expect(sameSelection.changedMeshes, 0);
      expect(sameSelection.uploadedBytes, 0);
      encoder.accept(sameSelection);
      scene.outline = null;
      final removed = encoder.encode(capture());
      expect(removed.changedMeshes, 1);
      expect(removed.uploadedBytes, 0);
      expect(capture().scene.drawCalls, 2);
    },
  );

  test('style and exclusion edits invalidate without geometry edits', () {
    final scene = Scene();
    final mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    final before = scene.revision;
    scene.outline = SceneOutline(objects: [mesh]);
    expect(scene.revision, greaterThan(before));
    final active = scene.revision;
    scene.outline = scene.outline;
    expect(scene.revision, active);
    mesh.outlineEnabled = false;
    expect(scene.revision, greaterThan(active));
    for (final width in [0, 9]) {
      expect(
        () => SceneOutline(objects: [mesh], width: width),
        throwsArgumentError,
      );
    }
    for (final opacity in [-.1, 1.1, double.nan]) {
      expect(
        () => SceneOutline(objects: [mesh], opacity: opacity),
        throwsArgumentError,
      );
    }
  });
}
