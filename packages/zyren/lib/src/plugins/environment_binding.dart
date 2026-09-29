part of 'engine.dart';

/// One attachment provides environment lighting for its view. Publish prepared
/// replacements in beforeRender. The map's resource scope owns GPU lifetime.
final class EnvironmentBinding {
  Environment? _environment;
  bool _closed = false;
  EnvironmentBinding._();
  Environment? get environment => _environment;
  set environment(Environment? value) {
    if (_closed) throw StateError('Environment binding has closed.');
    if (value?.map.isClosed ?? false) {
      throw StateError('Environment map has closed.');
    }
    _environment = value;
  }

  void _close() {
    _closed = true;
    _environment = null;
  }
}

extension PluginEnvironment on PluginContext {
  /// Claim during attach. Custom lighting plugins may prepare maps from their
  /// own procedural textures through EnvironmentMap.prefilter.
  EnvironmentBinding get environment {
    _checkAttached();
    if (_environment case final binding?) return binding;
    if (!_registering) {
      throw StateError('Claim environment lighting during attach.');
    }
    if (!capabilities.supports(RenderFeature.environmentLighting)) {
      throw _unsupported(
        RenderFeature.environmentLighting,
        'attach',
        'This backend cannot bind environment lighting.',
      );
    }
    final binding = _claimEnvironment();
    scope.keep(Registration(binding._close));
    return _environment = binding;
  }
}
