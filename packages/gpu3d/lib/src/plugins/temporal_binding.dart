part of 'engine.dart';

/// One attachment owns native temporal reconstruction for its view.
final class TemporalBinding {
  TemporalAAOptions? _options;
  int _generation = 0;
  bool _closed = false;
  TemporalBinding._();
  TemporalAAOptions? get options => _options;
  int get generation => _generation;
  set options(TemporalAAOptions? value) {
    if (_closed) throw StateError('Temporal binding has closed.');
    if (identical(value, _options)) return;
    _options = value;
    reset();
  }

  void reset() {
    if (_closed) throw StateError('Temporal binding has closed.');
    _generation++;
  }

  void _close() {
    _closed = true;
    _options = null;
  }
}

extension PluginTemporal on PluginContext {
  TemporalBinding get temporal {
    _checkAttached();
    if (_temporal case final binding?) return binding;
    if (!_registering) {
      throw StateError('Claim temporal reconstruction during attach.');
    }
    if (!capabilities.supports(RenderFeature.temporalAntialiasing)) {
      throw _unsupported(
        RenderFeature.temporalAntialiasing,
        'attach',
        'This backend does not support temporal antialiasing.',
      );
    }
    final binding = _claimTemporal();
    scope.keep(Registration(binding._close));
    return _temporal = binding;
  }
}
