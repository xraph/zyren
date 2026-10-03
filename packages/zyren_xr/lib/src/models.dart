import 'dart:math' as math;

enum XrSessionState { ready, starting, running, paused, interrupted, failed }

enum XrTrackingState { unavailable, limited, normal }

enum XrCameraPermission { notDetermined, authorized, denied, restricted }

final class XrException implements Exception {
  final String code, message;
  final Object? details;
  const XrException(this.code, this.message, [this.details]);
  @override
  String toString() => 'XrException($code): $message';
}

final class XrCapabilities {
  final String platform;
  final String? availability;
  final bool worldTracking, planeDetection, anchors, lightEstimation;
  final bool sceneDepthHardware, cameraPresentation, depthOcclusion;
  final XrCameraPermission cameraPermission;

  XrCapabilities.fromMessage(Object? value) : this._(messageMap(value));

  XrCapabilities._(Map<Object?, Object?> m)
    : platform = messageString(m, 'platform'),
      availability = m['availability'] as String?,
      worldTracking = messageBool(m, 'worldTracking'),
      planeDetection = messageBool(m, 'planeDetection'),
      anchors = messageBool(m, 'anchors'),
      lightEstimation = messageBool(m, 'lightEstimation'),
      sceneDepthHardware = messageBool(m, 'sceneDepthHardware'),
      cameraPresentation = messageBool(m, 'cameraPresentation'),
      depthOcclusion = messageBool(m, 'depthOcclusion'),
      cameraPermission = messageEnum(
        m,
        'cameraPermission',
        XrCameraPermission.values,
      );
}

final class XrConfiguration {
  final bool horizontalPlanes, verticalPlanes, lightEstimation;

  /// Required features fail explicitly until the renderer implements them.
  final bool requireCameraPresentation, requireDepthOcclusion;
  const XrConfiguration({
    this.horizontalPlanes = true,
    this.verticalPlanes = true,
    this.lightEstimation = true,
    this.requireCameraPresentation = false,
    this.requireDepthOcclusion = false,
  });

  Map<String, Object> toMessage() => {
    'horizontalPlanes': horizontalPlanes,
    'verticalPlanes': verticalPlanes,
    'lightEstimation': lightEstimation,
    'requireCameraPresentation': requireCameraPresentation,
    'requireDepthOcclusion': requireDepthOcclusion,
  };
}

/// Right-handed rigid transform in metres, stored in column-major order.
/// ARKit camera poses use the image sensor's orientation, not the UI orientation.
final class XrPose {
  final List<double> matrix;

  XrPose(Iterable<num> values)
    : matrix = List.unmodifiable(values.map((v) => v.toDouble())) {
    if (matrix.length != 16 || matrix.any((v) => !v.isFinite)) {
      throw ArgumentError('A pose needs 16 finite column-major values.');
    }
    const tolerance = 0.002;
    final m = matrix;
    if (m[3].abs() > tolerance ||
        m[7].abs() > tolerance ||
        m[11].abs() > tolerance ||
        (m[15] - 1).abs() > tolerance) {
      throw ArgumentError('A pose must be affine.');
    }
    for (var a = 0; a < 3; a++) {
      for (var b = 0; b < 3; b++) {
        final dot =
            m[a * 4] * m[b * 4] +
            m[a * 4 + 1] * m[b * 4 + 1] +
            m[a * 4 + 2] * m[b * 4 + 2];
        if ((dot - (a == b ? 1 : 0)).abs() > tolerance) {
          throw ArgumentError('A pose cannot contain scale or shear.');
        }
      }
    }
    final determinant =
        m[0] * (m[5] * m[10] - m[9] * m[6]) -
        m[4] * (m[1] * m[10] - m[9] * m[2]) +
        m[8] * (m[1] * m[6] - m[5] * m[2]);
    if ((determinant - 1).abs() > tolerance * 2) {
      throw ArgumentError('A pose must preserve handedness.');
    }
  }

  factory XrPose.identity() =>
      XrPose([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
}

final class XrLightEstimate {
  final double ambientIntensity;
  final double? colorTemperature;
  final String intensityUnit;
  final List<double>? colorCorrection;
  XrLightEstimate.fromMessage(Object? value) : this._(messageMap(value));
  XrLightEstimate._(Map<Object?, Object?> m)
    : ambientIntensity = messageNumber(m, 'ambientIntensity'),
      colorTemperature = m['colorTemperature'] == null
          ? null
          : messageNumber(m, 'colorTemperature'),
      intensityUnit = m['intensityUnit'] as String? ?? 'lumens',
      colorCorrection = m['colorCorrection'] == null
          ? null
          : List.unmodifiable(messageNumbers(m, 'colorCorrection', 4));
}

final class XrAnchor {
  final String id;
  final XrPose pose;
  XrAnchor.fromMessage(Object? value) : this._(messageMap(value));
  XrAnchor._(Map<Object?, Object?> m)
    : id = messageString(m, 'id'),
      pose = XrPose(messageNumbers(m, 'transform', 16));
}

final class XrPlane {
  final String id, alignment;
  final XrPose pose;
  final List<double> center, extent;
  XrPlane.fromMessage(Object? value) : this._(messageMap(value));
  XrPlane._(Map<Object?, Object?> m)
    : id = messageString(m, 'id'),
      alignment = messageString(m, 'alignment'),
      pose = XrPose(messageNumbers(m, 'transform', 16)),
      center = messageNumbers(m, 'center', 3),
      extent = messageNumbers(m, 'extent', 3);
}

final class XrFrame {
  /// Seconds on ARKit's monotonic clock, not a wall-clock date.
  final double timestamp;
  final XrPose cameraPose;
  final XrTrackingState tracking;
  final String? trackingReason;
  final List<double> intrinsics;
  final int imageWidth, imageHeight;
  final XrLightEstimate? light;
  final List<XrAnchor> anchors;
  final List<XrPlane> planes;
  final int omittedPlanes;

  XrFrame.fromMessage(Object? value) : this._(messageMap(value));
  XrFrame._(Map<Object?, Object?> m)
    : timestamp = messageNumber(m, 'timestamp'),
      cameraPose = XrPose(messageNumbers(m, 'cameraTransform', 16)),
      tracking = messageEnum(m, 'tracking', XrTrackingState.values),
      trackingReason = m['trackingReason'] == null
          ? null
          : messageString(m, 'trackingReason'),
      intrinsics = messageNumbers(m, 'intrinsics', 9),
      imageWidth = messageInt(m, 'imageWidth', minimum: 1),
      imageHeight = messageInt(m, 'imageHeight', minimum: 1),
      light = m['light'] == null
          ? null
          : XrLightEstimate.fromMessage(m['light']),
      anchors = List.unmodifiable(
        messageList(m, 'anchors', 128).map(XrAnchor.fromMessage),
      ),
      planes = List.unmodifiable(
        messageList(m, 'planes', 128).map(XrPlane.fromMessage),
      ),
      omittedPlanes = messageInt(m, 'omittedPlanes');

  /// Age measured using another timestamp from the same native clock.
  double ageAt(double nativeTimestamp) {
    if (!nativeTimestamp.isFinite) throw ArgumentError.value(nativeTimestamp);
    return math.max(0, nativeTimestamp - timestamp);
  }
}

final class XrSnapshot {
  final String? sessionId;
  final int originEpoch;
  final XrSessionState state;
  final int revision;
  final XrFrame? frame;
  final XrException? failure;
  final double nativeTimestamp;
  XrSnapshot.fromMessage(Object? value) : this._(messageMap(value));
  XrSnapshot._(Map<Object?, Object?> m)
    : sessionId = m['sessionId'] as String?,
      originEpoch = m.containsKey('originEpoch')
          ? messageInt(m, 'originEpoch')
          : 0,
      revision = messageInt(m, 'revision'),
      state = messageEnum(m, 'state', XrSessionState.values),
      nativeTimestamp = messageNumber(m, 'nativeTimestamp'),
      frame = m['frame'] == null ? null : XrFrame.fromMessage(m['frame']),
      failure = m['failure'] == null ? null : _failure(m['failure']);

  static XrException _failure(Object? value) {
    final m = messageMap(value);
    return XrException(
      messageString(m, 'code'),
      messageString(m, 'message'),
      m['details'],
    );
  }
}

Map<Object?, Object?> messageMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected an XR message map.');
  return value.cast<Object?, Object?>();
}

String messageString(Map m, String key) {
  final value = m[key];
  if (value is! String || value.isEmpty) throw FormatException('Invalid $key.');
  return value;
}

bool messageBool(Map m, String key) {
  final value = m[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}

double messageNumber(Map m, String key) {
  final value = m[key];
  if (value is! num || !value.isFinite) throw FormatException('Invalid $key.');
  return value.toDouble();
}

int messageInt(Map m, String key, {int minimum = 0}) {
  final value = m[key];
  if (value is! int || value < minimum) throw FormatException('Invalid $key.');
  return value;
}

T messageEnum<T extends Enum>(Map m, String key, List<T> values) {
  final name = messageString(m, key);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown $key: $name.');
}

List<Object?> messageList(Map m, String key, int limit) {
  final value = m[key];
  if (value is! List || value.length > limit) {
    throw FormatException('Invalid or oversized $key.');
  }
  return value.cast<Object?>();
}

List<double> messageNumbers(Map m, String key, int length) {
  final values = messageList(m, key, length);
  if (values.length != length || values.any((v) => v is! num || !v.isFinite)) {
    throw FormatException('Invalid $key.');
  }
  return List.unmodifiable(values.cast<num>().map((v) => v.toDouble()));
}
