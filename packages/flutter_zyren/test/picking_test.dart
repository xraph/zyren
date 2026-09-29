import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/backend_fake.dart';
import 'controller_test.dart' show frames, readback, runtime;

void main() {
  testWidgets(
    'shared scenes keep independent cameras and capture the pre-resize viewport',
    (tester) async {
      final scene = Scene();
      final left = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial())..position = const Vec3(-2, 0, 0),
      );
      final right = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial())..position = const Vec3(2, 0, 0),
      );
      SceneController make(double x) => SceneController(
        scene: scene,
        camera: PerspectiveCamera(
          position: Vec3(x, 0, 5),
          target: Vec3(x, 0, 0),
        ),
        options: readback,
        runtime: runtime(FakeBackend()),
      );
      final a = make(-2), b = make(2);
      Widget views(double width) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: width,
                height: 101,
                child: SceneView(controller: a),
              ),
              SizedBox(
                width: 101,
                height: 101,
                child: SceneView(controller: b),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(views(101));
      await frames(tester);
      final first = a.pick(const ViewportPoint(60.6, 50.5));
      final second = b.pick(const ViewportPoint(50.5, 50.5));
      await tester.pumpWidget(views(201));
      final leftHit = (await first)!, rightHit = (await second)!;
      expect(leftHit.object, same(left));
      expect(rightHit.object, same(right));
      expect(
        leftHit.point.x,
        closeTo(-2 + .2 * 4.5 * math.tan(25 * math.pi / 180), 1e-10),
      );
      expect(rightHit.point, const Vec3(2, 0, .5));
      final resized = a.pick(const ViewportPoint(60.6, 50.5));
      await tester.pump();
      expect(await resized, isNull);
      await tester.pumpWidget(const SizedBox());
      a.dispose();
      b.dispose();
      await frames(tester);
      await Future.wait([a.whenDisposed, b.whenDisposed]);
    },
  );
  testWidgets('input surface fills a loosely constrained viewport', (
    tester,
  ) async {
    final controller = SceneController(
      options: readback,
      runtime: runtime(FakeBackend()),
    );
    controller.scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: Align(
              alignment: Alignment.topLeft,
              child: SceneView(controller: controller),
            ),
          ),
        ),
      ),
    );
    await frames(tester);
    expect(tester.getSize(find.byType(SceneView)), const Size(200, 100));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await frames(tester);
    await controller.whenDisposed;
  });
  for (final dpr in [1.0, 1.5, 3.0]) {
    for (final scale in [.5, 1.0]) {
      testWidgets(
        'logical picks freeze pose and camera at DPR $dpr scale $scale',
        (tester) async {
          tester.view.devicePixelRatio = dpr;
          addTearDown(tester.view.resetDevicePixelRatio);
          final backend = FakeBackend()..maxDimension = 1000;
          final controller = SceneController(
            options: readback,
            runtime: runtime(backend),
          );
          final mesh = controller.scene.add(
            Mesh(BoxGeometry(), UnlitMaterial()),
          );
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: SizedBox(
                  width: 201,
                  height: 101,
                  child: SceneView(
                    controller: controller,
                    resolutionScale: scale,
                  ),
                ),
              ),
            ),
          );
          await frames(tester);
          final size = tester.getSize(find.byType(SceneView));
          final point = ViewportPoint(size.width * .525, size.height / 2);
          final revision = controller.scene.revision;
          final pending = controller.pick(point);
          mesh.position = const Vec3(100, 0, 0);
          controller.camera.position = const Vec3(20, 0, 5);
          await tester.pump();
          final hit = (await pending)!;
          expect(hit.object, same(mesh));
          expect(hit.sceneRevision, revision);
          expect(hit.point.z, closeTo(.5, 1e-9));
          expect(
            hit.point.x,
            closeTo(4.5 * .05 * math.tan(25 * math.pi / 180) * 201 / 101, 1e-9),
          );
          // Rounding the physical extent must not change the projection aspect.
          final projection = backend.submissions.first.camera.projection;
          expect(projection[5] / projection[0], closeTo(201 / 101, 1e-12));
          await tester.pumpWidget(const SizedBox());
          final detached = controller.pick(point);
          await expectLater(
            detached,
            throwsA(
              isA<SceneException>().having(
                (e) => e.issue.code,
                'code',
                SceneIssueCodes.invalidPickRequest,
              ),
            ),
          );
          controller.dispose();
          await frames(tester);
          await controller.whenDisposed;
        },
      );
    }
  }
  testWidgets(
    'zero-size and disposed views reject picks without failing rendering',
    (tester) async {
      final controller = SceneController(
        options: readback,
        runtime: runtime(FakeBackend()),
      );
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 0,
              height: 0,
              child: SceneView(controller: controller),
            ),
          ),
        ),
      );
      await frames(tester);
      await expectLater(
        controller.pick(const ViewportPoint(0, 0)),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.invalidPickRequest,
          ),
        ),
      );
      expect(controller.status.value, isNot(isA<SceneFailed>()));
      controller.dispose();
      await frames(tester);
      await controller.whenDisposed;
      await expectLater(
        controller.pick(const ViewportPoint(0, 0)),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.disposed,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
