import 'dart:math' as math;
import 'package:zyren/zyren.dart';

enum CloudTemporalMode { off, antialias, upscale }

enum CloudHistoryReset {
  firstFrame,
  none,
  explicit,
  resize,
  projection,
  parameters,
  sceneCut,
  cameraCut,
  lighting,
  time,
  failedFrame,
}

/// Source temporal alpha and Bayer reconstruction, with bounded history rejection.
final class CloudTemporalSettings {
  final CloudTemporalMode mode;
  final double alpha, varianceGamma, maxTranslation, maxRotation, maxElapsed;
  CloudTemporalSettings({
    this.mode = CloudTemporalMode.upscale,
    this.alpha = .1,
    this.varianceGamma = 2,
    this.maxTranslation = 10000,
    this.maxRotation = math.pi / 6,
    this.maxElapsed = .5,
  }) {
    for (final (v, min, max) in [
      (alpha, 0.0, 1.0),
      (varianceGamma, 0.0, 10.0),
      (maxTranslation, 0.0, 1e7),
      (maxRotation, 0.0, math.pi),
      (maxElapsed, 0.0, 10.0),
    ]) {
      if (!v.isFinite || v <= min || v > max) {
        throw ArgumentError('Invalid cloud temporal settings.');
      }
    }
  }
}

/// History becomes valid only after a frame has rendered successfully.
final class CloudHistoryStatus {
  final bool valid;
  final int accumulatedFrames;
  final CloudHistoryReset reason;
  const CloudHistoryStatus(this.valid, this.accumulatedFrames, this.reason);
}

final class CloudHistoryFrame {
  final Vec3 position, forward, up, sun;
  final Mat4 viewProjection;
  final String projection;
  final int width, height, number, revision, epoch, generation, frames;
  final Duration elapsed;
  final bool valid;
  final CloudHistoryReset reason;
  CloudHistoryFrame._(
    this.position,
    this.forward,
    this.up,
    this.sun,
    this.viewProjection,
    this.projection,
    this.width,
    this.height,
    this.number,
    this.revision,
    this.epoch,
    this.generation,
    this.frames,
    this.elapsed,
    this.valid,
    this.reason,
  );
}

/// Internal presentation transaction. An aborted frame never becomes history.
final class CloudHistory {
  CloudHistoryFrame? _previous;
  int _generation = 0;
  CloudHistoryReset _reset = CloudHistoryReset.firstFrame;
  CloudHistoryStatus get status => CloudHistoryStatus(
    _previous != null,
    _previous?.frames ?? 0,
    _previous?.reason ?? _reset,
  );
  CloudHistoryFrame? get previous => _previous;
  void invalidate([CloudHistoryReset reason = CloudHistoryReset.explicit]) {
    _previous = null;
    _generation++;
    _reset = reason;
  }

  CloudHistoryFrame begin({
    required Camera camera,
    required double aspect,
    required int width,
    required int height,
    required int number,
    required Duration elapsed,
    required int revision,
    required int epoch,
    required Vec3 sun,
    CloudTemporalSettings? settings,
  }) {
    final s = settings ?? CloudTemporalSettings(), p = _previous;
    final forward = (camera.target - camera.position).normalized(),
        up = camera.up.normalized();
    // Clipping changes depth mapping, not projected XY. History uses the
    // previous view-projection matrix and ray distance for reprojection.
    final projection =
        (camera is PerspectiveCamera
                ? [
                    0,
                    camera.fieldOfView,
                    camera.zoom,
                    aspect,
                    camera.depthStrategy.index,
                  ]
                : camera is OrthographicCamera
                ? [
                    1,
                    camera.left,
                    camera.right,
                    camera.bottom,
                    camera.top,
                    camera.zoom,
                    camera.depthStrategy.index,
                  ]
                : [camera.runtimeType, aspect, camera.depthStrategy.index])
            .join(',');
    var reason = _reset;
    if (p != null) {
      reason = width != p.width || height != p.height
          ? CloudHistoryReset.resize
          : epoch != p.epoch
          ? CloudHistoryReset.sceneCut
          : projection != p.projection
          ? CloudHistoryReset.projection
          : revision != p.revision
          ? CloudHistoryReset.parameters
          : elapsed < p.elapsed ||
                (elapsed - p.elapsed).inMicroseconds > 1e6 * s.maxElapsed
          ? CloudHistoryReset.time
          : sun.dot(p.sun) < .99995
          ? CloudHistoryReset.lighting
          : (camera.position - p.position).length > s.maxTranslation ||
                forward.dot(p.forward) < math.cos(s.maxRotation) ||
                up.dot(p.up) < math.cos(s.maxRotation)
          ? CloudHistoryReset.cameraCut
          : number != p.number + 1
          ? CloudHistoryReset.failedFrame
          : CloudHistoryReset.none;
    }
    final valid = reason == CloudHistoryReset.none;
    return CloudHistoryFrame._(
      camera.position,
      forward,
      up,
      sun,
      camera.viewProjection(aspect),
      projection,
      width,
      height,
      number,
      revision,
      epoch,
      _generation,
      valid ? p!.frames + 1 : 1,
      elapsed,
      valid,
      reason,
    );
  }

  void present(CloudHistoryFrame frame, int revision) {
    if (frame.generation != _generation || frame.revision != revision) {
      invalidate(CloudHistoryReset.parameters);
      return;
    }
    _previous = frame;
  }
}
