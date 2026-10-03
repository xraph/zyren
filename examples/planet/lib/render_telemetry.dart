import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_zyren/flutter_zyren.dart';

/// Optional measurements for normal apps, without the integration test binding.
final class RenderTelemetry {
  final Future<Map<String, Object?>> Function() snapshot;
  final _clock = Stopwatch()..start();
  final _samples = <Map<String, Object?>>[];
  late final StreamSubscription<PresentationSample> _frames;
  int? _firstFrame;
  bool _closed = false;
  RenderTelemetry(SceneController controller, this.snapshot) {
    _frames = controller.presentations.listen((sample) {
      final frame = sample.frame;
      final now = _clock.elapsedMicroseconds;
      _firstFrame ??= now;
      _samples.add({
        'atUs': now,
        'buildUs': frame.cpuBuildTime.inMicroseconds,
        'submitUs': frame.cpuSubmitTime.inMicroseconds,
        'gpuUs': frame.gpuTime?.inMicroseconds,
        'profile': frame.profile?.toJson(),
        'readbackBytes': frame.readbackBytes,
        'size': [frame.physicalSize.width, frame.physicalSize.height],
      });
      if (_samples.length > 240) _samples.removeAt(0);
    });
    developer.registerExtension('ext.planet.renderStatus', (_, _) async {
      final result = _closed
          ? <String, Object?>{'closed': true}
          : await snapshot();
      return developer.ServiceExtensionResponse.result(
        jsonEncode({
          ...result,
          'firstFrameUs': _firstFrame,
          'samples': List.of(_samples),
        }),
      );
    });
  }
  Future<void> close() async {
    _closed = true;
    await _frames.cancel();
  }
}
