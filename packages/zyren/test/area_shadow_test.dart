import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

FrameSubmission capture(Scene scene) => FrameSubmission.capture(
  scene: scene,
  camera: PerspectiveCamera(position: const Vec3(0, 0, 3)),
  size: PhysicalSize(31, 31),
);
void main() {
  test('rectangular shadows capture four independent cube samples', () {
    final area = RectAreaLight(width: 4, height: 2, shadow: AreaShadow())
      ..position = const Vec3(0, 0, 2);
    final scene = Scene()
      ..add(area)
      ..add(DirectionalLight(shadow: DirectionalShadow(cascades: 1)));
    final first = capture(scene);
    expect(first.shadows.views.length, 25);
    expect(first.shadows.views.first.lightIndex, 0);
    expect(
      first.shadows.views.skip(1).map((v) => v.lightIndex),
      everyElement(16),
    );
    expect(first.shadows.views.skip(1).map((v) => v.kind), everyElement(3));
    expect(
      first.shadows.views[1].viewProjection,
      isNot(first.shadows.views[7].viewProjection),
    );
    area.invalidateShadow();
    expect(capture(scene).shadows.views[1].revision, 1);
    area.shadow = area.shadow!.copyWith(strength: .3);
    expect(capture(scene).shadows.views[1].settings.strength, .3);
    area.shadow = null;
    expect(capture(scene).shadows.views.length, 1);
  });
  test('four area emitters fit default atlas and reject oversized maps', () {
    final scene = Scene();
    for (var i = 0; i < 4; i++) {
      scene.add(RectAreaLight(shadow: AreaShadow()));
    }
    expect(capture(scene).shadows.views.length, 96);
    for (final light in scene.children.cast<RectAreaLight>()) {
      light.shadow = AreaShadow(resolution: 512);
    }
    expect(() => capture(scene), throwsArgumentError);
    expect(() => AreaShadow(near: 2, far: 1), throwsArgumentError);
  });
}
