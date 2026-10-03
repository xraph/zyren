import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_xr/zyren_xr.dart';

Map<String, Object?> calibrationMessage({
  int frame = 1,
  int epoch = 1,
  bool landscape = false,
  List<double>? pose,
}) => {
  'frameId': frame,
  'revision': 3,
  'epoch': epoch,
  'timestamp': 12.0,
  'pixelWidth': landscape ? 1200 : 600,
  'pixelHeight': landscape ? 600 : 1200,
  'logicalWidth': landscape ? 600.0 : 300.0,
  'logicalHeight': landscape ? 300.0 : 600.0,
  'devicePixelRatio': 2.0,
  'orientation': landscape ? 3 : 1,
  'projection': PerspectiveCamera(
    fieldOfView: math.pi / 2,
    near: .1,
    far: 100,
  ).projectionMatrix(landscape ? 2 : .5).storage,
  'cameraTransform': pose ?? XrPose.identity().matrix,
  'displayTransform': [1.0, 0.0, 0.0, 1.0, 0.0, 0.0],
};

void main() {
  test('depth calibration must describe the captured camera timestamp', () {
    final message = calibrationMessage()
      ..['depthEnabled'] = true
      ..['depthTimestamp'] = 12.0;
    expect(XrCalibration.fromMessage(message).depthEnabled, isTrue);
    message['depthTimestamp'] = 11.9;
    expect(
      () => XrCalibration.fromMessage(message),
      throwsA(isA<XrException>()),
    );
    message.remove('depthTimestamp');
    expect(
      () => XrCalibration.fromMessage(message),
      throwsA(isA<XrException>()),
    );
  });
  test('mapped depth clocks preserve raw camera and depth agreement', () {
    final message = calibrationMessage()
      ..['depthEnabled'] = true
      ..['depthTimestamp'] = 12.0
      ..['sensorTimestamp'] = 1000000.0
      ..['depthSensorTimestamp'] = 1000000.0;
    final calibration = XrCalibration.fromMessage(message);
    expect(calibration.timestamp, 12.0);
    expect(calibration.sensorTimestamp, 1000000.0);
    message['depthSensorTimestamp'] = 999999.9;
    expect(
      () => XrCalibration.fromMessage(message),
      throwsA(isA<XrException>()),
    );
    message.remove('depthSensorTimestamp');
    expect(
      () => XrCalibration.fromMessage(message),
      throwsA(isA<XrException>()),
    );
  });

  for (final landscape in [false, true]) {
    test(
      'calibrated ${landscape ? 'landscape' : 'portrait'} camera keeps camera-relative translation',
      () {
        final pose = XrPose.identity().matrix.toList()
          ..[12] = 1000
          ..[13] = 5
          ..[14] = 20;
        final calibration = XrCalibration.fromMessage(
          calibrationMessage(landscape: landscape, pose: pose),
        );
        final camera = XrCamera(calibration);
        final center = camera.projectPoint(const Vec3(1000, 5, 18), 1);
        expect(center.x, closeTo(0, 1e-10));
        expect(center.y, closeTo(0, 1e-10));
        final right = camera.projectPoint(const Vec3(1001, 5, 18), 1);
        expect(right.x, closeTo(landscape ? .25 : 1, 1e-10));
        final restored = camera.unprojectPoint(right, 1);
        expect((restored - const Vec3(1001, 5, 18)).length, lessThan(1e-8));
      },
    );
  }
  test(
    'scene-from-session applies rotation and translation to camera axes',
    () {
      final sceneFromSession = Mat4([
        0,
        1,
        0,
        0,
        -1,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
        9,
        8,
        7,
        1,
      ]);
      final camera = XrCamera(
        XrCalibration.fromMessage(calibrationMessage()),
        sceneFromSession: sceneFromSession,
      );
      expect(camera.position, const Vec3(9, 8, 7));
      final point = camera.projectPoint(const Vec3(9, 9, 5), 1);
      expect(point.x, closeTo(1, 1e-10));
      expect(point.y, closeTo(0, 1e-10));
      expect(
        () => XrCamera(
          camera.calibration,
          sceneFromSession: Mat4([
            2,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
          ]),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'orientation-adjusted pose rotates screen axes without changing depth',
    () {
      final pose = [
        0.0,
        1.0,
        0.0,
        0.0,
        -1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
      ];
      final camera = XrCamera(
        XrCalibration.fromMessage(calibrationMessage(pose: pose)),
      );
      final screenRight = camera.projectPoint(const Vec3(0, 1, -2), 1);
      expect(screenRight.x, closeTo(1, 1e-10));
      expect(screenRight.y, closeTo(0, 1e-10));
      expect(screenRight.z, inExclusiveRange(0, 1));
    },
  );
}
