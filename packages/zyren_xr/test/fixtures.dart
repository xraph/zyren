import 'dart:async';
import 'package:zyren_xr/zyren_xr.dart';

Map<String, Object?> capabilitiesMessage() => {
  'platform': 'arkit',
  'worldTracking': true,
  'planeDetection': true,
  'anchors': true,
  'lightEstimation': true,
  'sceneDepthHardware': true,
  'cameraPresentation': false,
  'depthOcclusion': false,
  'cameraPermission': 'authorized',
};

Map<String, Object?> snapshotMessage({
  String tracking = 'normal',
  int revision = 1,
}) => {
  'state': 'running',
  'revision': revision,
  'nativeTimestamp': 12.1,
  'frame': {
    'timestamp': 12.0,
    'cameraTransform': XrPose.identity().matrix,
    'tracking': tracking,
    if (tracking == 'limited') 'trackingReason': 'initializing',
    'intrinsics': [1000.0, 0.0, 0.0, 0.0, 1000.0, 0.0, 960.0, 720.0, 1.0],
    'imageWidth': 1920,
    'imageHeight': 1440,
    'anchors': <Object?>[],
    'planes': <Object?>[],
    'omittedPlanes': 0,
    'light': {'ambientIntensity': 900.0, 'colorTemperature': 6200.0},
  },
};

final class RecordingTransport implements XrTransport {
  final calls = <(String, Map<String, Object?>)>[];
  FutureOr<Object?> Function(String, Map<String, Object?>)? handler;
  Map<String, Object?> current = snapshotMessage();
  @override
  Future<Object?> invoke(String method, Map<String, Object?> arguments) async {
    calls.add((method, arguments));
    if (handler != null) return await handler!(method, arguments);
    return switch (method) {
      'create' => {'sessionId': 'session-1'},
      'capabilities' => capabilitiesMessage(),
      'snapshot' => current,
      'addAnchor' => {'anchorId': 'anchor-1'},
      _ => null,
    };
  }
}
