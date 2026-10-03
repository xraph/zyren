import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

void main() {
  test(
    'publication keeps rendered and picked ownership distinct and caches stable',
    () {
      final scene = Scene();
      final group = scene.add(PublicationGroup());
      final old = Mesh(BoxGeometry(), UnlitMaterial());
      final next = Mesh(BoxGeometry(), UnlitMaterial())
        ..position = const Vec3(0, 0, 1);
      final camera = PerspectiveCamera();
      final raycaster = Raycaster();
      RaycastSnapshot capture() => raycaster.captureFromCamera(
        scene,
        camera,
        const ViewportPoint(50, 50),
        logicalWidth: 100,
        logicalHeight: 100,
      );
      group.stage([old]);
      group.publish([old]);
      expect(capture().intersectFirst()!.object, same(old));
      group.stage([next]);
      expect(group.children, [old, next]);
      expect(group.renderChildren, [next]);
      final frozen = capture();
      final revision = scene.revision;
      group.stage([next]);
      group.publish([old]);
      expect(scene.revision, revision);
      expect(capture().intersectFirst()!.object, same(old));
      group.publish([next]);
      expect(frozen.intersectFirst()!.object, same(old));
      expect(capture().intersectFirst()!.object, same(next));
      expect(old.parent, isNull);
      next.layers = LayerMask.only(1);
      expect(capture().intersectFirst(), isNull);
      camera.layers = LayerMask.all;
      expect(capture().intersectFirst()!.object, same(next));
      scene.clippingPlanes = [
        ClippingPlane(normal: const Vec3(0, 0, 1), offset: 3),
      ];
      expect(capture().intersectFirst(), isNull);
      group.clippingEnabled = false;
      expect(capture().intersectFirst()!.object, same(next));
    },
  );
}
