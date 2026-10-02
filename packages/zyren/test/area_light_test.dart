import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

class NoAreaRenderer extends TestRenderer {
  NoAreaRenderer() : super([]);
  @override
  RendererCapabilities get capabilities =>
      RendererCapabilities(name: 'no areas', features: {}, maxDimension: 64);
}

FrameSubmission capture(Scene scene, {Vec3 origin = Vec3.zero}) =>
    FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(
        position: origin,
        target: origin + const Vec3(0, 0, -1),
      ),
      size: PhysicalSize(31, 31),
    );

void main() {
  test('unsupported area lights fail before renderer submission', () async {
    final renderer = NoAreaRenderer();
    final light = RectAreaLight();
    final engine = await SceneEngine.create(
      scene: Scene()..add(light),
      camera: PerspectiveCamera(),
      rendererFactory: () async => renderer,
    );
    try {
      await expectLater(
        engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31),
        throwsA(isA<SceneException>()),
      );
      expect(renderer.renders, 0);
      light.visible = false;
      await engine.renderFrame(elapsed: Duration.zero, width: 31, height: 31);
      expect(renderer.renders, 1);
    } finally {
      await engine.dispose();
    }
  });
  test('area lights capture camera-relative affine rectangles', () {
    final scene = Scene();
    final group = scene.add(Group()..position = const Vec3(1e10, 0, 0));
    final light = group.add(
      RectAreaLight(width: 4, height: 2, intensity: 3)
        ..position = const Vec3(2, 0, 5)
        ..scale = const Vec3(2, 3, 1),
    );
    final packet = capture(
      scene,
      origin: const Vec3(1e10, 0, 0),
    ).toNativePacket();
    final area = (packet['areas'] as List).single as Map;
    expect(area['position'], [2, 0, 5]);
    expect(area['half_width'], [4, 0, 0]);
    expect(area['half_height'], [0, 3, 0]);
    expect(area['intensity'], 3);
    light.lookAt(const Vec3(3, 0, 5));
    final edited =
        ((capture(scene).toNativePacket()['areas'] as List).single as Map);
    final width = edited['half_width'] as List;
    expect((width[0] as double).abs(), lessThan(1e-10));
    expect((width[2] as double).abs(), closeTo(4, 1e-10));
  });
  test(
    'area dimensions, counts and visibility are validated before encoding',
    () {
      for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
        expect(() => RectAreaLight(width: invalid), throwsArgumentError);
        expect(() => RectAreaLight(height: invalid), throwsArgumentError);
      }
      final scene = Scene();
      final light = RectAreaLight();
      expect(() => light.width = 0, throwsArgumentError);
      expect(light.width, 1);
      for (var i = 0; i < 5; i++) {
        scene.add(RectAreaLight());
      }
      expect(() => capture(scene), throwsArgumentError);
      scene.children.last.visible = false;
      expect(capture(scene).scene.areaLightCount, 4);
      scene.children.first.layers = LayerMask.only(1);
      expect(capture(scene).scene.areaLightCount, 3);
      expect(
        () => scene.snapshot(PerspectiveCamera(), 1),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'area edits preserve accepted geometry while advancing the scene frame',
    () {
      final scene = Scene()..add(Mesh(PlaneGeometry(), StandardMaterial()));
      final light = scene.add(RectAreaLight()..position = const Vec3(0, 0, 2));
      final encoder = ScenePacketEncoder(viewId: 9);
      encoder.accept(encoder.encode(capture(scene)));
      light.width = 3;
      light.rotateY(math.pi / 4);
      final next = encoder.encode(capture(scene));
      expect(next.uploadedBytes, 0);
      expect(next.changedMeshes, 0);
      expect(next.bytes, isNotEmpty);
    },
  );
}
