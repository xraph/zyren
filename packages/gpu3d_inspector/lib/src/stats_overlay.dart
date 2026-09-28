import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

/// Samples presented-frame statistics without acquiring render demand or input.
/// The controller is borrowed. Unavailable measurements remain explicit.
class SceneStatsOverlay extends StatefulWidget {
  final SceneController controller;
  final Duration refreshInterval;
  const SceneStatsOverlay({
    super.key,
    required this.controller,
    this.refreshInterval = const Duration(milliseconds: 500),
  });
  @override
  State<SceneStatsOverlay> createState() => _SceneStatsOverlayState();
}

class _SceneStatsOverlayState extends State<SceneStatsOverlay> {
  StreamSubscription<FrameStats>? _subscription;
  Timer? _timer;
  FrameStats? _shown, _pending;
  @override
  void initState() {
    super.initState();
    _bind();
  }

  void _validateInterval() {
    if (widget.refreshInterval <= Duration.zero) {
      throw ArgumentError.value(
        widget.refreshInterval,
        'refreshInterval',
        'Must be positive.',
      );
    }
  }

  void _bind() {
    _validateInterval();
    final controller = widget.controller;
    _shown = controller.latestFrameStats;
    controller.status.addListener(_statusChanged);
    _subscription = controller.frameStats.listen((value) {
      if (!mounted || !identical(controller, widget.controller)) return;
      _pending = value;
      _timer ??= Timer(widget.refreshInterval, () {
        _timer = null;
        if (mounted) {
          setState(() {
            _shown = _pending;
            _pending = null;
          });
        }
      });
    });
  }

  void _statusChanged() {
    if (!mounted) return;
    final status = widget.controller.status.value;
    if (status is SceneFailed ||
        status is SceneDisposed ||
        status is SceneRecovering ||
        status is SceneInitializing) {
      _timer?.cancel();
      _timer = null;
      _pending = null;
      _shown = null;
    }
    setState(() {});
  }

  void _unbind(SceneController controller) {
    controller.status.removeListener(_statusChanged);
    unawaited(_subscription?.cancel());
    _subscription = null;
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  @override
  void didUpdateWidget(SceneStatsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        oldWidget.refreshInterval != widget.refreshInterval) {
      _unbind(oldWidget.controller);
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind(widget.controller);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _shown;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.bodySmall!,
            child: stats == null
                ? const Text('No presented frame')
                : Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      Text('Last frame ${stats.frameId}'),
                      Text(
                        '${stats.drawCalls} draws · ${stats.triangles} triangles',
                      ),
                      Text(
                        '${stats.physicalSize.width} × ${stats.physicalSize.height} · ${stats.presentationPath.name}',
                      ),
                      Text(
                        'Build ${_time(stats.cpuBuildTime)} · encode ${_time(stats.cpuSubmitTime)}',
                      ),
                      Text(
                        'GPU ${stats.gpuTime == null ? 'unavailable' : _time(stats.gpuTime!)}',
                      ),
                      Text(
                        'Upload ${_bytes(stats.uploadedBytes)} · readback ${_bytes(stats.readbackBytes)}',
                      ),
                      Text(
                        'Resident ${stats.residentBytes == null ? 'unavailable' : _bytes(stats.residentBytes!)}',
                      ),
                      Text(
                        '${stats.computeDispatches} compute · ${stats.coalescedFrames} coalesced · ${stats.droppedFrames} dropped',
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

String _time(Duration value) =>
    '${(value.inMicroseconds / 1000).toStringAsFixed(2)} ms';
String _bytes(int value) => value < 1024
    ? '$value B'
    : value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)} KiB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
