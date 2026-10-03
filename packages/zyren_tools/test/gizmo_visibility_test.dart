import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  for (final overlay in [false, true]) {
    test(
      'alwaysVisible=$overlay keeps rendering and picking consistent',
      () async {
        final scene = Scene();
        final selected = scene.add(
          Mesh(BoxGeometry(width: .2, height: .2, depth: .2), UnlitMaterial()),
        );
        scene.add(
          Mesh(BoxGeometry(width: 8, height: 8, depth: .2), UnlitMaterial())
            ..position = const Vec3(0, 0, 2),
        );
        final camera = OrthographicCamera(
          left: -3,
          right: 3,
          top: 3,
          bottom: -3,
          position: const Vec3(0, 0, 6),
          near: .1,
          far: 10,
        );
        final tools = SceneToolsPlugin(highlightSelection: false);
        final gizmo = TransformGizmoPlugin(alwaysVisible: overlay);
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => TestRenderer([]),
          plugins: [tools, gizmo],
        );
        try {
          tools.select(selected);
          const viewport = ViewportMetrics(600, 600);
          final projected = camera.projectPoint(const Vec3(.6, 0, 0), 1);
          final hit = gizmo.hitTestHandle(
            ViewportPoint((projected.x + 1) * 300, (1 - projected.y) * 300),
            viewport,
          );
          expect(hit, overlay ? GizmoAxis.x : isNull);
          void inspect(Object3D node) {
            if (node is Mesh && gizmo.owns(node)) {
              expect(node.material.depthTest, !gizmo.alwaysVisible);
              expect(node.material.writesDepth, !gizmo.alwaysVisible);
              expect(node.renderOrder, gizmo.alwaysVisible ? 0x7fffffff : 0);
            }
            for (final child in node.children) {
              inspect(child);
            }
          }

          inspect(scene);
          gizmo.alwaysVisible = !overlay;
          inspect(scene);
          expect(
            gizmo.hitTestHandle(
              ViewportPoint((projected.x + 1) * 300, (1 - projected.y) * 300),
              viewport,
            ),
            overlay ? isNull : GizmoAxis.x,
          );
          gizmo.alwaysVisible = overlay;
          inspect(scene);
          gizmo.mode = GizmoMode.rotate;
          ViewportPoint ringPoint(double angle) {
            final p = camera.projectPoint(
              Vec3(1.275 * math.cos(angle), 1.275 * math.sin(angle), 0),
              1,
            );
            return ViewportPoint((p.x + 1) * 300, (1 - p.y) * 300);
          }

          final start = ringPoint(math.pi / 4);
          expect(
            gizmo.hitTestHandle(start, viewport),
            overlay ? GizmoAxis.z : isNull,
          );
          if (overlay) {
            gizmo.handlePointer(
              ScenePointerEvent(
                phase: ScenePointerPhase.down,
                point: start,
                pointer: 1,
                kind: ScenePointerKind.mouse,
                buttons: 1,
              ),
              viewport,
            );
            expect(gizmo.isDragging, isTrue);
            gizmo.handlePointer(
              ScenePointerEvent(
                phase: ScenePointerPhase.up,
                point: ringPoint(math.pi / 4 + .4),
                pointer: 1,
                kind: ScenePointerKind.mouse,
                buttons: 1,
              ),
              viewport,
            );
            expect(selected.quaternion.z, closeTo(math.sin(.2), 1e-6));
            expect(gizmo.isDragging, isFalse);
            expect(tools.undo(), isTrue);
            expect(selected.quaternion, Quat.identity);
          }
        } finally {
          await engine.dispose();
        }
        expect(scene.children.where(gizmo.owns), isEmpty);
      },
    );
  }
}
