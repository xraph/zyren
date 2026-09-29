import 'dart:async';
import '../assets/hdr_image.dart';
import '../math/quat.dart';
import '../plugins/engine.dart';
import '../plugins/attachment_scope.dart';
import '../plugins/registration.dart';
import '../rendering/capabilities.dart';
import '../resources/resource_scope.dart';

/// Lights standard materials from a linear HDR panorama. Keep one instance per
/// view. Image replacements prepare asynchronously and become visible at the
/// next frame boundary; failed preparation leaves the current lighting intact.
final class EnvironmentLighting extends ScenePlugin {
  @override
  final String id;
  final EnvironmentQuality quality;
  HdrImageData? _image;
  double _intensity;
  Quat _rotation;
  PluginContext? _context;
  EnvironmentBinding? _binding;
  ResourceScope? _resources;
  EnvironmentMap? _active, _candidate;
  bool _hasCandidate = false;
  Future<void> _tail = Future.value();

  EnvironmentLighting({
    HdrImageData? image,
    this.quality = const EnvironmentQuality(),
    double intensity = 1,
    Quat rotation = Quat.identity,
    this.id = 'zyren.environment',
  }) : _image = image,
       _intensity = _validateIntensity(intensity),
       _rotation = rotation.normalized() {
    quality.validate();
  }

  /// The map selected at the last frame boundary. Its lifetime belongs to this
  /// plugin; use EnvironmentMap.retain to keep it in another resource scope.
  EnvironmentMap? get map => _active;
  HdrImageData? get image => _image;
  double get intensity => _intensity;
  set intensity(double value) {
    _intensity = _validateIntensity(value);
    _context?.invalidate();
  }

  Quat get rotation => _rotation;
  set rotation(Quat value) {
    _rotation = value.normalized();
    _context?.invalidate();
  }

  static double _validateIntensity(double value) {
    if (!value.isFinite || value < 0 || value > 1e6) {
      throw ArgumentError.value(value, 'intensity', 'Use [0, 1000000].');
    }
    return value;
  }

  @override
  Set<RenderFeature> get requiredFeatures => const {
    RenderFeature.environmentLighting,
    RenderFeature.standardMaterials,
    RenderFeature.hdrColor,
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.renderGraphs,
    RenderFeature.compute,
    RenderFeature.storageTextures,
  };

  /// Completes when the replacement is prepared. Requests run in order. Pass
  /// null to disable lighting at the next frame; calls before attach set the
  /// initial image without allocating GPU resources.
  Future<void> setImage(HdrImageData? image) {
    final context = _context;
    if (context == null) {
      _image = image;
      return Future.value();
    }
    final resources = _resources!;
    final operation = _tail.then((_) async {
      if (!identical(_context, context)) {
        throw StateError('Environment attachment ended before preparation.');
      }
      final candidate = image == null
          ? null
          : await EnvironmentMap.fromEquirectangular(
              image,
              resources: resources,
              quality: quality,
            );
      try {
        if (!identical(_context, context)) {
          throw StateError('Environment attachment ended during preparation.');
        }
        // An unpublished candidate has never been captured by a frame.
        final previous = _candidate;
        _candidate = null;
        _hasCandidate = false;
        await previous?.close();
        if (!identical(_context, context)) {
          throw StateError('Environment attachment ended during replacement.');
        }
        _candidate = candidate;
        _hasCandidate = true;
        _image = image;
        context.invalidate();
      } catch (_) {
        await candidate?.close();
        rethrow;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  @override
  Future<void> attach(PluginContext context) async {
    _binding = context.environment;
    _resources = context.resources;
    _context = context;
    context.scope.keep(Registration(() => _context = null));
    await setImage(_image);
    await _publish();
  }

  Future<void> _publish() async {
    if (_context == null) return;
    final previous = _active;
    if (_hasCandidate) {
      _active = _candidate;
      _candidate = null;
      _hasCandidate = false;
    }
    final active = _active;
    _binding!.environment = active == null
        ? null
        : Environment(map: active, intensity: _intensity, rotation: _rotation);
    if (!identical(previous, active)) await previous?.close();
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      _publish();

  @override
  Future<void> detach(PluginContext context) async {
    _context = null;
    await _tail;
    final maps = [_candidate, _active];
    _candidate = _active = null;
    _hasCandidate = false;
    _binding = null;
    _resources = null;
    final errors = <Object>[];
    for (final map in maps) {
      try {
        await map?.close();
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isNotEmpty) throw ScopeCleanupException(errors);
  }
}
