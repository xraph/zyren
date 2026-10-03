import 'package:zyren/zyren.dart';

import 'models.dart';

/// Calibration belongs to one retained camera image and one native viewport.
final class XrCalibration {
  final int frameId, revision, epoch, pixelWidth, pixelHeight, orientation;
  final double timestamp, logicalWidth, logicalHeight, devicePixelRatio;
  final Mat4 projection;
  final XrPose cameraPose;
  final List<double> displayTransform;
  XrCalibration.fromMessage(Object? value) : this._(messageMap(value));
  XrCalibration._(Map<Object?, Object?> map)
    : frameId = (map['frameId'] as num).toInt(),
      revision = (map['revision'] as num).toInt(),
      epoch = (map['epoch'] as num).toInt(),
      pixelWidth = (map['pixelWidth'] as num).toInt(),
      pixelHeight = (map['pixelHeight'] as num).toInt(),
      orientation = (map['orientation'] as num).toInt(),
      timestamp = (map['timestamp'] as num).toDouble(),
      logicalWidth = (map['logicalWidth'] as num).toDouble(),
      logicalHeight = (map['logicalHeight'] as num).toDouble(),
      devicePixelRatio = (map['devicePixelRatio'] as num).toDouble(),
      projection = Mat4(
        (map['projection'] as List).cast<num>().map((v) => v.toDouble()),
      ),
      cameraPose = XrPose(
        (map['cameraTransform'] as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList(),
      ),
      displayTransform = List.unmodifiable(
        (map['displayTransform'] as List).cast<num>().map((v) => v.toDouble()),
      ) {
    if (pixelWidth < 1 ||
        pixelHeight < 1 ||
        pixelWidth > 4096 ||
        pixelHeight > 4096 ||
        !timestamp.isFinite ||
        !logicalWidth.isFinite ||
        logicalWidth <= 0 ||
        !logicalHeight.isFinite ||
        logicalHeight <= 0 ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0 ||
        displayTransform.length != 6 ||
        displayTransform.any((v) => !v.isFinite)) {
      throw const XrException(
        'invalidCalibration',
        'The native camera calibration is invalid.',
      );
    }
  }
}

/// ARKit's orientation-adjusted camera in the scene's session coordinate system.
/// The view matrix omits translation because Zyren uses camera-relative models.
final class XrCamera extends Camera {
  final XrCalibration calibration;
  final Mat4 sceneFromSession;
  late final Mat4 _rotationView;
  late Vec3 _target, _up;
  XrCamera(this.calibration, {Mat4? sceneFromSession})
    : sceneFromSession = sceneFromSession ?? Mat4.identity() {
    // Require a rigid transform so scene metres and calibrated depth stay valid.
    XrPose(this.sceneFromSession.storage);
    final pose =
        (this.sceneFromSession * Mat4(calibration.cameraPose.matrix)).storage;
    position = Vec3(pose[12], pose[13], pose[14]);
    _target = position - Vec3(pose[8], pose[9], pose[10]);
    _up = Vec3(pose[4], pose[5], pose[6]);
    final rotation = pose.toList()
      ..[12] = 0
      ..[13] = 0
      ..[14] = 0;
    _rotationView = Mat4(rotation).inverted();
  }
  @override
  Vec3 get target => _target;
  @override
  set target(Vec3 value) =>
      throw UnsupportedError('XR camera orientation comes from calibration.');
  @override
  Vec3 get up => _up;
  @override
  set up(Vec3 value) =>
      throw UnsupportedError('XR camera orientation comes from calibration.');
  @override
  Mat4 projectionMatrix(double aspect) => calibration.projection;
  @override
  Mat4 viewProjection(double aspect) => calibration.projection * _rotationView;
}
