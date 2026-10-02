import 'package:zyren/zyren.dart';
import 'dithering.dart';
import 'grading.dart';
import 'hald.dart';
import 'lens.dart';
import 'smaa.dart';

const screenEffects = ServiceKey<ScreenEffectsController>('effects.screen');

/// Lens operates in HDR; grading, SMAA and dither follow tone mapping in that
/// order. Null lens, grading or SMAA values disable the corresponding effect.
final class ScreenEffectsSettings {
  final LensFlareSettings? lens;
  final HaldLookup? grading;
  final HaldInterpolation interpolation;
  final double gradingIntensity;
  final SmaaPreset? smaa;
  final bool dithering;
  ScreenEffectsSettings({
    this.lens,
    this.grading,
    this.interpolation = HaldInterpolation.trilinear,
    this.gradingIntensity = 1,
    this.smaa = SmaaPreset.medium,
    this.dithering = true,
  }) {
    if (!gradingIntensity.isFinite ||
        gradingIntensity < 0 ||
        gradingIntensity > 1) {
      throw ArgumentError.value(gradingIntensity, 'gradingIntensity');
    }
  }
  int get stageCount =>
      (lens == null ? 0 : 22) +
      (grading == null ? 0 : 1) +
      (smaa == null ? 0 : 3) +
      (dithering ? 1 : 0);
}

/// Owns an effect chain and rebuilds it on viewport changes. Exposure, tone
/// mapping and native output AA remain under your scene's render settings.
final class ScreenEffectsPlugin extends ScenePlugin {
  final ScreenEffectsSettings settings;
  ScreenEffectsController? _controller;
  ScreenEffectsPlugin({ScreenEffectsSettings? settings})
    : settings = settings ?? ScreenEffectsSettings();
  ScreenEffectsController get controller =>
      _controller ?? (throw StateError('Screen effects are not attached.'));
  @override
  String get id => 'screen-effects';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.shaderMaterials,
    RenderFeature.floatTextures,
    RenderFeature.volumeTextures,
    RenderFeature.postprocessing,
    RenderFeature.hdr,
  };
  @override
  void attach(PluginContext context) {
    final control = _controller = ScreenEffectsController._(
      context,
      context.createGpuScope(label: 'screen effects'),
      settings,
    );
    context.scope.onClose(control._close);
    context.provide(screenEffects, control);
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._frame(frame);
}

final class ScreenEffectsController {
  final PluginContext _context;
  final GpuScope _owner;
  ScreenEffectsSettings _settings;
  final _slots = <EffectRegistration>[];
  _EffectsCandidate? _active;
  Future<void> _queue = Future.value();
  bool _closed = false;
  int _width = 0, _height = 0, _generation = 0;
  ScreenEffectsController._(this._context, this._owner, this._settings);
  bool get isClosed => _closed || _owner.isClosed;
  ScreenEffectsSettings get settings => _settings;
  int get width => _width;
  int get height => _height;
  int get generation => _generation;
  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) {
      if (isClosed) throw StateError('Screen effects have closed.');
      return action();
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> setSettings(ScreenEffectsSettings value) => _serial(() async {
    if (_width > 0) await _replace(value, PhysicalSize(_width, _height));
    _settings = value;
    _context.invalidate();
  });
  Future<void> _frame(FrameInfo frame) => _serial(() async {
    if (_width != frame.width || _height != frame.height) {
      await _replace(_settings, PhysicalSize(frame.width, frame.height));
    }
  });
  void _capacity(ScreenEffectsSettings value) {
    if (_context.scene.effects.length - _slots.length + value.stageCount > 32) {
      throw StateError('Screen effects exceed the scene effect limit.');
    }
  }

  Future<void> _replace(ScreenEffectsSettings value, PhysicalSize size) async {
    _capacity(value);
    final scope = _owner.createChild(label: 'screen effect candidate');
    final candidate = _EffectsCandidate(scope);
    try {
      if (value.lens case final lens?) {
        candidate.stages.addAll(
          (await LensFlareEffect.create(scope, size, settings: lens)).stages,
        );
      }
      if (value.grading case final lut?) {
        candidate.stages.add(
          (await ColorGradingEffect.create(
            scope,
            lut: lut,
            interpolation: value.interpolation,
            intensity: value.gradingIntensity,
          )).effect,
        );
      }
      if (value.smaa case final preset?) {
        candidate.stages.addAll(
          (await SmaaEffect.create(scope, size, preset: preset)).stages,
        );
      }
      if (value.dithering) {
        candidate.stages.add((await DitheringEffect.create(scope)).effect);
      }
      if (isClosed) throw StateError('Screen effects have closed.');
      _capacity(value);
      final previous = _active;
      if (_slots.length == candidate.stages.length) {
        for (var i = 0; i < _slots.length; i++) {
          _slots[i].replace(candidate.stages[i]);
        }
      } else {
        for (final slot in _slots) {
          slot.dispose();
        }
        _slots.clear();
        for (var i = 0; i < candidate.stages.length; i++) {
          _slots.add(
            _context.scene.addEffect(candidate.stages[i], order: 100 + i),
          );
        }
      }
      _active = candidate;
      _width = size.width;
      _height = size.height;
      _generation++;
      await previous?.scope.close();
    } catch (_) {
      if (!identical(_active, candidate)) await scope.close();
      rethrow;
    }
  }

  Future<void> _close() async {
    _closed = true;
    await _queue;
    for (final slot in _slots) {
      slot.dispose();
    }
    _slots.clear();
    await _active?.scope.close();
    _active = null;
  }
}

final class _EffectsCandidate {
  final GpuScope scope;
  final stages = <ScreenEffect>[];
  _EffectsCandidate(this.scope);
}
