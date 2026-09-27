import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

Vec3 vector(Object? value) =>
    Vec3.array((value as List).map((v) => (v as num).toDouble()).toList());

void main() {
  test('cameras match Three r184 projection and picking fixtures', () {
    final fixture =
        jsonDecode(File('test/fixtures/three_cameras.json').readAsStringSync())
            as Map;
    expect(fixture['three'], '0.184.0');
    var maxMatrix = 0.0, maxProjection = 0.0;
    var maxOrigin = 0.0, maxDirection = 0.0, maxRoundTrip = 0.0;
    for (final row in fixture['rows'] as List) {
      final position = vector(row['position']), target = vector(row['target']);
      final up = vector(row['up']), zoom = (row['zoom'] as num).toDouble();
      final aspect = (row['aspect'] as num).toDouble();
      final Camera camera = row['kind'] == 'perspective'
          ? PerspectiveCamera(
              position: position,
              target: target,
              up: up,
              zoom: zoom,
              fieldOfView: 50 * math.pi / 180,
              near: 1,
              far: 1e5,
            )
          : OrthographicCamera(
              position: position,
              target: target,
              up: up,
              zoom: zoom,
              left: -3,
              right: 5,
              bottom: -2,
              top: 4,
              near: 0,
              far: 1e5,
            );
      final matrix = camera.viewProjection(aspect).storage;
      for (var i = 0; i < 16; i++) {
        maxMatrix = math.max(maxMatrix, (matrix[i] - row['matrix'][i]).abs());
      }
      for (final sample in row['samples'] as List) {
        final point = vector(sample['point']);
        final projected = camera.projectPoint(point, aspect);
        maxProjection = math.max(
          maxProjection,
          projected.distanceTo(vector(sample['projected'])),
        );
        maxRoundTrip = math.max(
          maxRoundTrip,
          camera.unprojectPoint(projected, aspect).distanceTo(point),
        );
        final xy = sample['xy'] as List;
        final ray = camera.rayFromNdc(
          (xy[0] as num).toDouble(),
          (xy[1] as num).toDouble(),
          aspect,
        );
        maxOrigin = math.max(
          maxOrigin,
          ray.origin.distanceTo(vector(sample['origin'])),
        );
        maxDirection = math.max(
          maxDirection,
          ray.direction.distanceTo(vector(sample['direction'])),
        );
        final rayProjected = camera.projectPoint(ray.at(50), aspect);
        expect(rayProjected.x, closeTo(xy[0], 1e-8));
        expect(rayProjected.y, closeTo(xy[1], 1e-8));
        expect(ray.direction.length, closeTo(1, 1e-12));
      }
    }
    expect(maxMatrix, lessThan(1e-12));
    expect(maxProjection, lessThan(5e-9));
    expect(maxRoundTrip, lessThan(1e-9));
    expect(maxOrigin, lessThan(5e-9));
    expect(maxDirection, lessThan(5e-10));
    print(
      'Three camera errors: matrix=$maxMatrix projection=$maxProjection '
      'roundTrip=$maxRoundTrip rayOrigin=$maxOrigin rayDirection=$maxDirection',
    );
  });

  test('orthographic depth, zoom, off-center bounds and parallel rays', () {
    final camera = OrthographicCamera(
      position: Vec3.zero,
      target: const Vec3(0, 0, -1),
      left: -3,
      right: 5,
      bottom: -2,
      top: 4,
      near: 0,
      far: 100,
    );
    expect(camera.projectPoint(const Vec3(1, 1, 0), 1), Vec3.zero);
    expect(camera.projectPoint(const Vec3(5, 4, -100), 1), const Vec3(1, 1, 1));
    camera.zoom = 2;
    expect(
      camera
          .projectPoint(const Vec3(3, 2.5, -50), 1)
          .distanceTo(const Vec3(1, 1, .5)),
      lessThan(1e-12),
    );
    expect(camera.viewProjection(.5), camera.viewProjection(2));
    final a = camera.rayFromNdc(-1, 1, 1), b = camera.rayFromNdc(1, -1, 1);
    expect(a.direction, b.direction);
    expect(a.origin, const Vec3(-1, 2.5, 0));
    expect(b.origin, const Vec3(3, -.5, 0));
  });

  test('frustum changes are atomic and revisioned', () {
    final camera = OrthographicCamera();
    final revision = camera.revision;
    camera.zoom = 2;
    expect(camera.revision, greaterThan(revision));
    final zoomRevision = camera.revision;
    camera.zoom = 2;
    expect(camera.revision, zoomRevision);
    camera.setFrustum(left: 3, right: 5, bottom: 10, top: 20);
    expect(camera.left, 3);
    expect(camera.top, 20);
    expect(() => camera.setFrustum(left: 30, bottom: 40), throwsArgumentError);
    expect(camera.left, 3);
    expect(camera.bottom, 10);
    camera.setClippingRange(2000, 3000);
    expect(camera.near, 2000);
    expect(camera.far, 3000);
    expect(() => camera.setClippingRange(4000, 3000), throwsArgumentError);
    expect(camera.near, 2000);
    final perspective = PerspectiveCamera();
    perspective.setClippingRange(2000, 3000);
    expect(perspective.near, 2000);
    expect(perspective.far, 3000);
    expect(() => perspective.setClippingRange(0, 1), throwsArgumentError);
  });

  test('invalid projections and rays fail before rendering', () {
    expect(() => OrthographicCamera(left: 2, right: 1), throwsArgumentError);
    expect(() => OrthographicCamera(near: -1), throwsArgumentError);
    expect(() => OrthographicCamera(zoom: 0), throwsArgumentError);
    expect(() => OrthographicCamera(up: Vec3.zero), throwsArgumentError);
    expect(
      () => OrthographicCamera(target: const Vec3(0, 0, 5)),
      throwsArgumentError,
    );
    expect(
      () => OrthographicCamera(up: const Vec3(0, 0, 1)),
      throwsArgumentError,
    );
    expect(() => PerspectiveCamera(zoom: double.nan), throwsArgumentError);
    for (final camera in <Camera>[PerspectiveCamera(), OrthographicCamera()]) {
      expect(() => camera.viewProjection(0), throwsArgumentError);
      expect(() => camera.rayFromNdc(double.nan, 0, 1), throwsArgumentError);
      expect(
        () => camera.projectPoint(const Vec3(double.infinity, 0, 0), 1),
        throwsArgumentError,
      );
      expect(
        () => camera.unprojectPoint(const Vec3(0, double.nan, 0), 1),
        throwsArgumentError,
      );
    }
    expect(() => CameraRay(Vec3.zero, Vec3.zero), throwsArgumentError);
    expect(
      () => CameraRay(Vec3.zero, const Vec3(0, 0, -1)).at(double.infinity),
      throwsArgumentError,
    );
    final perspective = PerspectiveCamera();
    expect(
      () => perspective.projectPoint(perspective.position, 1),
      throwsArgumentError,
    );
  });
}
