import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../extension.dart';
import '../waves/sea_state.dart';
import 'controller.dart';
import 'settings.dart';
import 'view.dart';

/// Native single-scene globe presentation for OceanExtension. The factory
/// supplies an ECEF configuration matching this scene's camera and actual size.
/// Viewport replacements are prepared before retiring the previous controller.
final class OceanNativePresentation implements OceanPresentation {
  final GeospatialContext context;
  final OceanSeaState state;
  final OceanViewConfiguration Function(FrameInfo) configureView;
  final int Function() retainedBytes;
  final Duration transitionDuration;
  @override
  final bool hasUnderwater;
  final GpuScope _scope;
  OceanQualitySettings _quality;
  OceanQualitySettings? _requestedQuality;
  OceanController<OceanViewSet>? _controller;
  OceanViewConfiguration? _configuration;
  bool _closed = false, _rebuild = false;
  Completer<void>? _pending;
  Future<void>? _closing;
  final List<Object> _retirementFailures = [];
  int _unretiredBytes = 0;
  Object? lastFailure;
  OceanNativePresentation({
    required this.context,
    required this.state,
    required OceanQualitySettings quality,
    required this.configureView,
    this.hasUnderwater = false,
    this.transitionDuration = const Duration(milliseconds: 400),
    int Function()? retainedBytes,
  }) : retainedBytes = retainedBytes ?? _noRetained,
       _quality = quality,
       _scope = context.sceneContext.createGpuScope(
         label: 'ocean-presentation',
       );
  static int _noRetained() => 0;
  OceanController<OceanViewSet>? get controller => _controller;
  OceanViewResources? get view => _configuration == null
      ? null
      : _controller?.resources.view(_configuration!.id);
  OceanQualitySettings get effectiveQuality =>
      _controller?.effectiveQuality ?? _quality;
  List<Object> get retirementFailures => List.unmodifiable(_retirementFailures);
  @override
  bool get isReady =>
      !_closed && (_controller?.isReady ?? false) && (view?.isReady ?? false);

  /// Applies on the next frame under its owner. Rejection retains the old profile
  /// and is reported through lastFailure and the extension's layer status.
  void requestQuality(OceanQualitySettings quality) {
    _check();
    _requestedQuality = quality;
    context.sceneContext.invalidate();
  }

  void requestLodUpdate() {
    _check();
    _rebuild = true;
    context.sceneContext.invalidate();
  }

  void _check() {
    if (_closed || _scope.isClosed) {
      throw StateError('Ocean presentation closed.');
    }
  }

  @override
  Future<void> prepare(
    GeoInstant instant,
    FrameInfo frame,
    OceanLayerVisibility visibility,
  ) async {
    _check();
    if (_pending != null) throw StateError('Ocean presentation is busy.');
    final done = _pending = Completer<void>();
    try {
      final previousConfig = _configuration;
      if (previousConfig == null ||
          previousConfig.size.width != frame.width ||
          previousConfig.size.height != frame.height ||
          !identical(previousConfig.camera, context.sceneContext.camera) ||
          previousConfig.sampleCount !=
              context.sceneContext.scene.renderSettings.sampleCount) {
        await _replace(instant, frame, visibility);
      } else {
        final target = _requestedQuality;
        if (target != null && !_controller!.isTransitioning) {
          _requestedQuality = null;
          await _controller!.setQuality(target);
          _quality = _controller!.effectiveQuality;
        }
        if (_rebuild && !_controller!.isTransitioning) {
          _rebuild = false;
          await _controller!.rebuild();
        }
        await _controller!.advance(
          seconds: instant.seconds,
          elapsed: frame.elapsed,
        );
        _check();
        await view!.setVisibility(
          surface: visibility.surface,
          foam: visibility.foam,
          underwater: visibility.underwater,
        );
        view!.attach(context.sceneContext.scene);
      }
      lastFailure = null;
    } catch (error) {
      lastFailure = error;
      rethrow;
    } finally {
      _pending = null;
      done.complete();
    }
  }

  Future<void> _replace(
    GeoInstant instant,
    FrameInfo frame,
    OceanLayerVisibility visibility,
  ) async {
    final config = configureView(frame), host = context.reference.ellipsoid;
    if (!identical(config.camera, context.sceneContext.camera) ||
        config.size.width != frame.width ||
        config.size.height != frame.height ||
        config.sampleCount !=
            context.sceneContext.scene.renderSettings.sampleCount ||
        config.ellipsoid.x != host.x ||
        config.ellipsoid.y != host.y ||
        config.ellipsoid.z != host.z ||
        (config.underwater != null) != hasUnderwater) {
      throw ArgumentError(
        'Ocean view must match its scene camera, viewport, samples, host ellipsoid and underwater capability.',
      );
    }
    OceanController<OceanViewSet>? candidate;
    var oldBytes = _controller?.estimatedBytes ?? 0;
    final target = _requestedQuality ?? _quality;
    _requestedQuality = null;
    try {
      candidate = await OceanController.create<OceanViewSet>(
        _scope,
        state: state,
        chartIds: const [0, 1, 2, 3, 4, 5],
        capabilities: context.sceneContext.capabilities,
        quality: target,
        transitionDuration: transitionDuration,
        seconds: instant.seconds,
        retainedBytes: () => retainedBytes() + oldBytes + _unretiredBytes,
        plan: (settings, previous) => OceanViewSet.plan(
          settings: settings,
          views: [config],
          captureViewFactory: context.sceneContext.createCaptureView,
          previous: previous == null ? null : candidate!.resources,
        ),
      );
      await candidate.advance(seconds: instant.seconds, elapsed: frame.elapsed);
      final next = candidate.resources.view(config.id);
      await next.setVisibility(
        surface: visibility.surface,
        foam: visibility.foam,
        underwater: visibility.underwater,
      );
      _check();
      next.attach(context.sceneContext.scene, replaceConfiguration: true);
    } catch (_) {
      await candidate?.close();
      rethrow;
    }
    final previous = _controller;
    _controller = candidate;
    _configuration = config;
    _quality = candidate.effectiveQuality;
    _rebuild = false;
    try {
      await previous?.close();
    } catch (error) {
      _unretiredBytes += oldBytes;
      if (_retirementFailures.length == 16) _retirementFailures.removeAt(0);
      _retirementFailures.add(error);
    }
    oldBytes = 0;
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _pending?.future;
    final errors = <Object>[..._retirementFailures];
    try {
      await _controller?.close();
    } catch (error) {
      errors.add(error);
    }
    try {
      await _scope.close();
    } catch (error) {
      errors.add(error);
    }
    if (errors.isNotEmpty) throw ScopeCleanupException(errors);
  }
}
