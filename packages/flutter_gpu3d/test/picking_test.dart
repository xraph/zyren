import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime;

void main() {
  Widget host(
    SceneController controller, {
    double scale = 1,
    double width = 200,
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: width,
        height: 100,
        child: SceneView(controller: controller, resolutionScale: scale),
      ),
    ),
  );
  SceneController create(Camera camera) => SceneController(
    camera: camera,
    options: readback,
    runtime: runtime(FakeBackend()),
  );
  Mesh plane(double z) =>
      Mesh(PlaneGeometry(width: 100, height: 100), DiffuseMaterial())
        ..position = Vec3(0, 0, z);
  Matcher issue(String code) =>
      throwsA(isA<SceneException>().having((e) => e.issue.code, 'code', code));
  Future<void> close(WidgetTester tester, SceneController controller) async {
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
  }

  for (final dpr in [1.0, 2.5]) {
    for (final scale in [.5, 1.0]) {
      for (final ortho in [false, true]) {
        testWidgets('logical pick DPR $dpr scale $scale ortho $ortho', (
          tester,
        ) async {
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.resetDevicePixelRatio);
          final controller = create(
            ortho
                ? OrthographicCamera(
                    position: const Vec3(0, 0, 5),
                    left: -2,
                    right: 2,
                    bottom: -1,
                    top: 1,
                  )
                : PerspectiveCamera(
                    position: const Vec3(0, 0, 5),
                    fieldOfView: Angle.degrees(90),
                  ),
          );
          final mesh = plane(0);
          controller.scene.add(mesh);
          await tester.pumpWidget(host(controller, scale: scale));
          await frames(tester);
          final hit = (await controller.pick(const ViewportPoint(125, 25)))!;
          expect(hit.object, same(mesh));
          expect(hit.point.x, closeTo(ortho ? .5 : 2.5, 1e-10));
          expect(hit.point.y, closeTo(ortho ? .5 : 2.5, 1e-10));
          expect(hit.point.z, closeTo(0, 1e-10));
          await tester.pumpWidget(host(controller, scale: scale, width: 100));
          final resized = (await controller.pick(const ViewportPoint(50, 50)))!;
          expect(
            resized.point.distanceTo(const Vec3(0, 0, 0)),
            lessThan(1e-10),
          );
          await close(tester, controller);
        });
      }
    }
  }

  testWidgets('captures hit before camera, mesh and scene changes', (
    tester,
  ) async {
    final controller = create(PerspectiveCamera(position: const Vec3(0, 0, 5)));
    final mesh = plane(0);
    controller.scene.add(mesh);
    await tester.pumpWidget(host(controller));
    await frames(tester);
    final revision = controller.scene.revision;
    final request = controller.pick(const ViewportPoint(100, 50));
    mesh.position = const Vec3(0, 0, -10);
    controller.camera.position = const Vec3(0, 0, 20);
    controller.scene.remove(mesh);
    final hit = (await request)!;
    expect(hit.object, same(mesh));
    expect(hit.point, const Vec3(0, 0, 0));
    expect(hit.distance, 5);
    expect(hit.sceneRevision, revision);
    expect(await controller.pick(const ViewportPoint(100, 50)), isNull);
    await close(tester, controller);
  });

  testWidgets('camera clip planes use projection depth, not ray distance', (
    tester,
  ) async {
    final controller = create(
      PerspectiveCamera(
        position: const Vec3(0, 0, 5),
        near: 1,
        far: 5,
        fieldOfView: Angle.degrees(90),
      ),
    );
    final clippedNear = plane(4.5), visible = plane(1), clippedFar = plane(-1);
    controller.scene.add(clippedNear);
    controller.scene.add(visible);
    controller.scene.add(clippedFar);
    await tester.pumpWidget(host(controller));
    await frames(tester);
    var hit = (await controller.pick(const ViewportPoint(175, 50)))!;
    expect(hit.object, same(visible));
    expect(hit.distance, greaterThan(5));
    expect(hit.point.x, closeTo(6, 1e-10));
    visible.visible = false;
    expect(await controller.pick(const ViewportPoint(175, 50)), isNull);
    controller.camera = OrthographicCamera(
      position: const Vec3(0, 0, 5),
      near: 1,
      far: 5,
      left: -2,
      right: 2,
      bottom: -1,
      top: 1,
    );
    visible.visible = true;
    hit = (await controller.pick(const ViewportPoint(175, 50)))!;
    expect(hit.object, same(visible));
    expect(hit.point.x, closeTo(1.5, 1e-10));
    await close(tester, controller);
  });

  testWidgets(
    'skips a surface at the perspective eye and picks visible geometry',
    (tester) async {
      final controller = create(
        PerspectiveCamera(position: const Vec3(0, 0, 5)),
      );
      final eye = plane(5), visible = plane(0);
      controller.scene.add(eye);
      controller.scene.add(visible);
      await tester.pumpWidget(host(controller));
      await frames(tester);
      expect(
        (await controller.pick(const ViewportPoint(100, 50)))!.object,
        same(visible),
      );
      visible.visible = false;
      expect(await controller.pick(const ViewportPoint(100, 50)), isNull);
      controller.camera = OrthographicCamera(position: const Vec3(0, 0, 5));
      expect(
        (await controller.pick(const ViewportPoint(100, 50)))!.object,
        same(eye),
      );
      await close(tester, controller);
    },
  );

  testWidgets(
    'includes clip boundaries and excludes meaningfully outside planes',
    (tester) async {
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
      final controller = create(camera);
      final mesh = plane(5 - camera.near);
      controller.scene.add(mesh);
      await tester.pumpWidget(host(controller));
      await frames(tester);
      expect(
        (await controller.pick(const ViewportPoint(100, 50)))!.object,
        same(mesh),
      );
      mesh.position = Vec3(0, 0, 5 - camera.near + 1e-8);
      expect(await controller.pick(const ViewportPoint(100, 50)), isNull);
      mesh.position = Vec3(0, 0, 5 - camera.far);
      expect(
        (await controller.pick(const ViewportPoint(100, 50)))!.object,
        same(mesh),
      );
      mesh.position = Vec3(0, 0, 5 - camera.far - 1e-4);
      expect(await controller.pick(const ViewportPoint(100, 50)), isNull);
      await close(tester, controller);
    },
  );

  testWidgets(
    'misses outside and rejects invalid, detached and disposed queries',
    (tester) async {
      final controller = create(
        PerspectiveCamera(position: const Vec3(0, 0, 5)),
      );
      controller.scene.add(plane(0));
      await expectLater(
        controller.pick(const ViewportPoint(0, 0)),
        issue(SceneIssueCodes.invalidPickRequest),
      );
      await tester.pumpWidget(host(controller));
      await frames(tester);
      for (final point in [
        const ViewportPoint(-1, 50),
        const ViewportPoint(201, 50),
        const ViewportPoint(100, 101),
      ]) {
        expect(await controller.pick(point), isNull);
      }
      await expectLater(
        controller.pick(const ViewportPoint(double.nan, 0)),
        issue(SceneIssueCodes.invalidPickRequest),
      );
      await tester.pumpWidget(const SizedBox());
      await expectLater(
        controller.pick(const ViewportPoint(100, 50)),
        issue(SceneIssueCodes.invalidPickRequest),
      );
      controller.dispose();
      await expectLater(
        controller.pick(const ViewportPoint(100, 50)),
        issue(SceneIssueCodes.disposed),
      );
      await frames(tester);
      await controller.whenDisposed;
    },
  );
}
