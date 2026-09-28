part of 'clip.dart';

/// Register once on a view, then add mixers as models finish loading.
/// Dispose an add registration to release the mixer without resetting its pose.
final class AnimationSystem extends ScenePlugin {
  @override
  final String id;
  final _mixers = <AnimationMixer, Registration>{};
  PluginContext? _context;
  AnimationSystem({this.id = 'gpu3d.animationSystem'});
  List<AnimationMixer> get mixers => List.unmodifiable(_mixers.keys);

  Registration add(AnimationMixer mixer) {
    if (_mixers.length >= 4096) {
      throw StateError('An animation system supports at most 4096 mixers.');
    }
    if (mixer._system != null || mixer._context != null) {
      throw StateError('A mixer already belongs to a system or view.');
    }
    if (_context case final context?) mixer._attachContext(context);
    mixer._system = this;
    final registration = Registration(() {
      if (_context case final context?) mixer.detach(context);
      mixer._system = null;
      _mixers.remove(mixer);
    });
    _mixers[mixer] = registration;
    _context?.invalidate();
    return registration;
  }

  @override
  void attach(PluginContext context) {
    if (_context != null) {
      throw StateError('An animation system belongs to one view.');
    }
    _context = context;
    context.scope.onClose(() {
      if (identical(_context, context)) _context = null;
    });
    for (final mixer in _mixers.keys) {
      mixer._attachContext(context);
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    for (final mixer in _mixers.keys) {
      mixer._update(frame.delta, fromFrame: true);
    }
  }

  @override
  void detach(PluginContext context) {
    if (!identical(_context, context)) return;
    for (final mixer in _mixers.keys) {
      mixer.detach(context);
    }
    _context = null;
  }
}
