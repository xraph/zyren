import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/fakes.dart';

void main() {
  test(
    'animated transitions retain the visible depth convention until an endpoint',
    () {
      for (final from in DepthStrategy.values) {
        for (final to in DepthStrategy.values) {
          final manager = CameraTransitionManager(
            PerspectiveCamera(depthStrategy: from),
            OrthographicCamera(depthStrategy: to),
          );
          try {
            manager.toggle();
            manager.update(.05);
            expect(manager.camera.depthStrategy, from);
            manager.toggle();
            manager.update(.025);
            expect(manager.camera.depthStrategy, from);
            manager.update(1);
            expect(manager.camera.depthStrategy, from);
            manager.toggle();
            manager.update(1);
            expect(manager.camera.depthStrategy, to);
            manager.toggle();
            manager.update(.05);
            expect(manager.camera.depthStrategy, to);
            manager.update(1);
            expect(manager.camera.depthStrategy, from);
          } finally {
            manager.dispose();
          }
        }
      }
    },
  );

  for (final strategy in DepthStrategy.values) {
    for (final perspective in [true, false]) {
      test(
        '$strategy ${perspective ? 'perspective' : 'orthographic'} endpoints and rays',
        () {
          final Camera camera = perspective
              ? PerspectiveCamera(
                  position: Vec3.zero,
                  target: const Vec3(0, 0, -1),
                  near: 1,
                  far: 1000,
                  depthStrategy: strategy,
                )
              : OrthographicCamera(
                  position: Vec3.zero,
                  target: const Vec3(0, 0, -1),
                  near: 1,
                  far: 1000,
                  depthStrategy: strategy,
                );
          expect(
            camera.projectPoint(const Vec3(0, 0, -1), 1).z,
            closeTo(strategy.nearDepth, 1e-12),
          );
          expect(
            camera.projectPoint(const Vec3(0, 0, -1000), 1).z,
            closeTo(strategy.farDepth, 1e-12),
          );
          const point = Vec3(.2, .3, -50);
          final projected = camera.projectPoint(point, 1);
          expect(
            (camera.unprojectPoint(projected, 1) - point).length,
            lessThan(1e-9),
          );
          final ray = camera.rayFromNdc(projected.x, projected.y, 1);
          expect(
            (ray.at((point - ray.origin).dot(ray.direction)) - point).length,
            lessThan(1e-9),
          );
        },
      );
    }
  }

  test('float32 depth preserves a metre at horizon and orbit distances', () {
    final errors = <DepthStrategy, List<double>>{};
    for (final strategy in DepthStrategy.values) {
      final camera = PerspectiveCamera(
        position: Vec3.zero,
        target: const Vec3(0, 0, -1),
        near: .1,
        far: 1e9,
        depthStrategy: strategy,
      );
      errors[strategy] = [
        for (final distance in [1.0, 1000.0, 100000.0, 10000000.0])
          (camera
                      .unprojectPoint(
                        Vec3(
                          0,
                          0,
                          Float32List.fromList([
                            camera.projectPoint(Vec3(0, 0, -distance), 1).z,
                          ]).single,
                        ),
                        1,
                      )
                      .z +
                  distance)
              .abs(),
      ];
    }
    print('Float32 depth reconstruction errors in metres: $errors');
    expect(errors[DepthStrategy.reversed]![0], lessThan(1e-6));
    expect(errors[DepthStrategy.reversed]![1], lessThan(.001));
    expect(errors[DepthStrategy.reversed]![2], lessThan(.01));
    expect(errors[DepthStrategy.reversed]![3], lessThan(1));
    expect(errors[DepthStrategy.standard]![2], greaterThan(100));
    expect(errors[DepthStrategy.standard]![3], greaterThan(1e6));
  });

  test(
    'submissions freeze the strategy and legacy packets reject reversed depth',
    () {
      final camera = PerspectiveCamera(depthStrategy: DepthStrategy.reversed);
      final submission = FrameSubmission.capture(
        scene: Scene(),
        camera: camera,
        size: PhysicalSize(3, 3),
      );
      expect(() => Scene().snapshot(camera, 1), throwsUnsupportedError);
      camera.depthStrategy = DepthStrategy.standard;
      expect(submission.camera.depthStrategy, DepthStrategy.reversed);
      expect(submission.toNativePacket, throwsUnsupportedError);
      expect(ScenePacketEncoder(viewId: 1).encode(submission).bytes[4], 36);
    },
  );

  test(
    'engine rejects reversed depth on an unsupported backend before rendering',
    () async {
      final events = <String>[];
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(depthStrategy: DepthStrategy.reversed),
        rendererFactory: () async => TestRenderer(events),
      );
      try {
        await expectLater(
          engine.render(elapsed: Duration.zero, width: 3, height: 3),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.code,
              'code',
              SceneIssueCodes.unsupportedFeature,
            ),
          ),
        );
        expect(events, isNot(contains('test.render')));
      } finally {
        await engine.dispose();
      }
    },
  );
}
