import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_native/zyren_native.dart';

import 'calibration.dart';
import 'flutter_transport.dart';
import 'models.dart';
import 'raycast.dart';
import 'session.dart';

/// Owns camera presentation and scoped GPU resources for one XR session.
/// Close this controller before disposing its session.
final class XrPresentationController extends ChangeNotifier {
  final XrSession session;
  final XrTransport transport;
  final String presenterId;
  late final NativeGpuServices gpu = NativeGpuServices.withTransport((
    kind,
    bytes,
    capacity,
  ) async {
    final response = messageMap(
      await _invoke('gpuCommand', {
        'kind': kind.name,
        'bytes': bytes,
        'capacity': capacity,
      }),
    );
    return response['status'] == 0
        ? NativeGpuReply.success(response['bytes'] as Uint8List)
        : NativeGpuReply.failure(
            response['status'] as int,
            response['message'] as String,
          );
  });
  late final ScenePacketEncoder _encoder = gpu.createSceneEncoder(viewId: 1);
  Future<XrCalibration>? _frame;
  Future<void>? _closing;
  bool _closed = false, _gpuCleanupDone = false, _nativeClosed = false;
  (Object, StackTrace)? _gpuCleanupFailure;
  XrCalibration? _presented;
  int? _presentedSceneRevision;
  Map<String, Object?>? _diagnostics;

  /// Counters from the last successful native presentation, or null before one.
  Map<String, Object?>? get diagnostics => _diagnostics;
  XrCalibration? get presentedCalibration => _presented;
  int? get presentedSceneRevision => _presentedSceneRevision;
  bool get isRendering => _frame != null;

  /// Raycasts from the last presented camera, in viewport-local logical pixels.
  Future<XrRaycastResult> raycast(double x, double y) async {
    final calibration = _presented;
    if (_closed || calibration == null) {
      throw const XrException('staleFrame', 'Present a camera frame first.');
    }
    if (!x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        y < 0 ||
        x >= calibration.logicalWidth ||
        y >= calibration.logicalHeight) {
      throw ArgumentError('The point must lie inside the camera viewport.');
    }
    final result = XrRaycastResult.fromMessage(
      await _invoke('raycast', {
        'x': x,
        'y': y,
        'frameId': calibration.frameId,
        'epoch': calibration.epoch,
        'expectedRevision': calibration.revision,
      }),
    );
    if (_closed ||
        !identical(_presented, calibration) ||
        result.presenterId != presenterId ||
        result.frameId != calibration.frameId ||
        result.epoch != calibration.epoch ||
        result.frameTimestamp != calibration.timestamp ||
        result.sessionRevision != calibration.revision) {
      throw const XrException('staleFrame', 'The presented camera changed.');
    }
    return result;
  }

  XrPresentationController._(this.session, this.transport, this.presenterId);

  static Future<XrPresentationController> create({
    required XrSession session,
    XrTransport transport = const MethodChannelXrTransport(),
    int? runtimeToken,
  }) async {
    final response = messageMap(
      await transport.invoke('createPresenter', {
        'sessionId': session.id,
        'runtime': runtimeToken ?? NativeSurfaces().runtimeToken,
      }),
    );
    return XrPresentationController._(
      session,
      transport,
      messageString(response, 'presenterId'),
    );
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) => transport.invoke(method, {
    'sessionId': session.id,
    'presenterId': presenterId,
    ...args,
  });

  /// Acquires, encodes and presents the same retained camera frame.
  /// Only successful presentation updates [presentedCalibration].
  Future<XrCalibration> render(
    Scene scene, {
    Mat4? sceneFromSession,
    double near = .01,
    double far = 1000,
  }) {
    if (_closed) return Future.error(StateError('The XR presenter is closed.'));
    if (_frame != null) {
      return Future.error(
        const XrException('busy', 'A camera frame is in flight.'),
      );
    }
    if (scene.background != null || scene.backgroundOpacity != 0) {
      return Future.error(
        ArgumentError(
          'XR requires a transparent scene and no screen effects. Set scene.background = null and scene.backgroundOpacity = 0.',
        ),
      );
    }
    final pending = _render(scene, sceneFromSession, near, far);
    _frame = pending;
    return pending.whenComplete(() {
      _frame = null;
    });
  }

  Future<XrCalibration> _render(
    Scene scene,
    Mat4? transform,
    double near,
    double far,
  ) async {
    int? frameId;
    try {
      final raw = messageMap(
        await _invoke('acquireFrame', {'near': near, 'far': far}),
      );
      frameId = (raw['frameId'] as num).toInt();
      final calibration = XrCalibration.fromMessage(raw);
      if (_closed) throw StateError('The XR presenter is closing.');
      final camera = XrCamera(calibration, sceneFromSession: transform);
      final sceneRevision = scene.revision;
      final submission = FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(calibration.pixelWidth, calibration.pixelHeight),
      );
      if (submission.scene.usesScreenEffects) {
        throw ArgumentError('XR does not support screen effects.');
      }
      final packet = _encoder.encode(submission);
      final response = await gpu.submitFrame(
        submission,
        packet.bytes,
        (bytes) => _invoke('presentFrame', {
          'frameId': frameId,
          'revision': calibration.revision,
          'packet': bytes,
        }),
      );
      final receipt = messageMap(response);
      // Native rendering can finish before a resize or pause rejects presentation.
      // Keep the encoder's resource baseline aligned with that applied packet.
      if (receipt['applied'] == true || receipt['presented'] == true) {
        _encoder.accept(packet);
      }
      if (receipt['applied'] == true && receipt['presented'] == false) {
        throw const XrException(
          'frameDeferred',
          'The session or viewport changed during rendering.',
        );
      }
      if (receipt['presented'] != true ||
          receipt['frameId'] != frameId ||
          receipt['epoch'] != calibration.epoch) {
        throw const XrException(
          'invalidReceipt',
          'The presented frame does not match the acquired camera.',
        );
      }
      final presented = XrCalibration.fromMessage(receipt);
      if (!_closed) {
        _presented = presented;
        _presentedSceneRevision = sceneRevision;
        _diagnostics = Map.unmodifiable({
          for (final key in [
            'cameraReadbackBytes',
            'nativeReadbackBytes',
            'depthUploadBytes',
            'depthConfidenceMinimum',
            'inFlightLimit',
            'heldCameraFrames',
            'drawableLimit',
            'presentedFrames',
          ])
            key: receipt[key],
        });
        notifyListeners();
      }
      return presented;
    } finally {
      if (frameId != null) await _invoke('cancelFrame', {'frameId': frameId});
    }
  }

  /// Waits for in-flight work, retires GPU resources, then closes native rendering.
  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await _frame;
    } catch (_) {
      /* A failed frame still releases its lease. */
    }
    if (!_gpuCleanupDone) {
      try {
        await gpu.close();
      } catch (error, stack) {
        _gpuCleanupFailure = (error, stack);
      } finally {
        // NativeGpuServices caches its cleanup outcome, including failures.
        _gpuCleanupDone = true;
      }
    }
    if (!_nativeClosed) {
      try {
        await _invoke('closePresenter');
        _nativeClosed = true;
        _presented = null;
        _presentedSceneRevision = null;
        _diagnostics = null;
      } catch (error) {
        // Only native retirement can still be retried after GPU cleanup settles.
        _closing = null;
        if (_gpuCleanupFailure case (final cleanup, _)) {
          throw ScopeCleanupException([cleanup, error]);
        }
        rethrow;
      }
    }
    if (_gpuCleanupFailure case (final error, final stack)) {
      // Keep this terminal result so repeated close cannot target a removed view.
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  void dispose() {
    unawaited(
      close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }),
    );
    super.dispose();
  }
}

/// A native camera view. The controller renders on explicit frame demand.
class XrCameraView extends StatelessWidget {
  final XrPresentationController controller;
  const XrCameraView({super.key, required this.controller});
  @override
  Widget build(BuildContext context) =>
      defaultTargetPlatform == TargetPlatform.android
      ? AndroidView(
          key: ValueKey(controller.presenterId),
          viewType: 'dev.zyren.xr/vulkan.v1',
          creationParams: {'presenterId': controller.presenterId},
          creationParamsCodec: const StandardMessageCodec(),
        )
      : UiKitView(
          key: ValueKey(controller.presenterId),
          viewType: 'dev.zyren.xr/metal.v1',
          creationParams: {'presenterId': controller.presenterId},
          creationParamsCodec: const StandardMessageCodec(),
        );
}
