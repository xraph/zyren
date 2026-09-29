import '../plugins/engine.dart';
import '../plugins/registration.dart';
import '../rendering/capabilities.dart';
import '../rendering/frame_output.dart';
import '../rendering/temporal_aa_options.dart';

/// Jittered native temporal AA before graph effects. Requires single-sample HDR.
/// A still view requests eight accepted frames after scene/camera changes.
final class TemporalAntialiasing extends ScenePlugin {
  @override
  String get id => 'gpu3d.temporal-antialiasing';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.temporalAntialiasing,
    RenderFeature.hdrColor,
  };
  TemporalAAOptions _options;
  bool _enabled;
  TemporalBinding? _binding;
  PluginContext? _context;
  Registration? _demand;
  Object? _state;
  int _remaining = 8;
  TemporalAntialiasing({TemporalAAOptions? options, bool enabled = true})
    : _options = options ?? TemporalAAOptions(),
      _enabled = enabled;
  TemporalAAOptions get options => _options;
  set options(TemporalAAOptions value) {
    _options = value;
    _publish();
  }

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _publish();
  }

  void reset() {
    _binding?.reset();
    _state = null;
    _remaining = 8;
    _context?.invalidate();
  }

  void _publish() {
    _binding?.options = enabled ? options : null;
    _state = null;
    _remaining = 8;
    if (!enabled) {
      _demand?.dispose();
      _demand = null;
    }
    _context?.invalidate();
  }

  @override
  void attach(PluginContext context) {
    if (_context != null) {
      throw StateError('Use a separate temporal plugin for each view.');
    }
    _context = context;
    _binding = context.temporal;
    _publish();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (!enabled) return;
    final state = (
      context.scene.revision,
      context.camera.id,
      context.camera.revision,
      frame.width,
      frame.height,
      _binding!.generation,
    );
    if (state != _state) {
      _state = state;
      _remaining = 8;
    }
    if (_remaining > 0) _demand ??= context.acquireFrameDemand();
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    if (!enabled) return;
    if (_remaining > 0) _remaining--;
    if (_remaining == 0) {
      _demand?.dispose();
      _demand = null;
    }
  }

  @override
  void detach(PluginContext context) {
    if (!identical(context, _context)) return;
    _demand?.dispose();
    _demand = null;
    _binding = null;
    _context = null;
    _state = null;
  }
}
