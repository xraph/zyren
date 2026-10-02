import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'blur_wgsl.dart';
import 'lens_wgsl.dart';

/// Source lens controls. [maxResolution] bounds the longest working dimension.
final class LensFlareSettings {
  final double resolutionScale, intensity, thresholdLevel, thresholdRange;
  final double ghostAmount, haloAmount, chromaticAberration;
  final int maxResolution;
  LensFlareSettings({
    this.resolutionScale = .5,
    this.intensity = .005,
    this.thresholdLevel = 10,
    this.thresholdRange = 1,
    this.ghostAmount = .001,
    this.haloAmount = .001,
    this.chromaticAberration = 10,
    this.maxResolution = 512,
  }) {
    bool range(double v, double max) => v.isFinite && v >= 0 && v <= max;
    if (!range(resolutionScale, 1) ||
        resolutionScale == 0 ||
        !range(intensity, 16) ||
        !range(thresholdLevel, 65504) ||
        !range(thresholdRange, 65504) ||
        thresholdRange == 0 ||
        !range(ghostAmount, 16) ||
        !range(haloAmount, 16) ||
        !range(chromaticAberration, 64) ||
        maxResolution < 1 ||
        maxResolution > 1024) {
      throw ArgumentError('Invalid lens flare settings.');
    }
  }
}

/// Owns a 22-stage HDR lens pipeline. Prepare a replacement when the viewport or
/// settings change. Detach the scene registration before you close its resources.
final class LensFlareEffect {
  final GpuScope _scope;
  final List<ScreenEffect> stages;
  final GpuResource<Texture> threshold, bloom, features;
  LensFlareEffect._(
    this._scope,
    List<ScreenEffect> stages,
    this.threshold,
    this.bloom,
    this.features,
  ) : stages = List.unmodifiable(stages);
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();

  LensFlareAttachment attach(Scene scene, {int order = 100}) {
    _validate();
    RangeError.checkValueInInterval(
      order,
      -32768,
      32767 - stages.length + 1,
      'order',
    );
    if (scene.effects.length + stages.length > 32) {
      throw StateError('Lens flare exceeds the scene effect limit.');
    }
    return LensFlareAttachment._([
      for (var i = 0; i < stages.length; i++)
        scene.addEffect(stages[i], order: order + i),
    ]);
  }

  void _validate() {
    if (isClosed || stages.any((e) => e.isClosed)) {
      throw StateError('Lens flare owner has closed.');
    }
  }

  static Future<LensFlareEffect> create(
    GpuScope owner,
    PhysicalSize size, {
    LensFlareSettings? settings,
  }) async {
    final options = settings ?? LensFlareSettings();
    final scale = math.min(
      options.resolutionScale,
      options.maxResolution / math.max(size.width, size.height),
    );
    final width = math.max(1, (size.width * scale).round()),
        height = math.max(1, (size.height * scale).round());
    final scope = owner.createChild(label: 'Lens flare');
    try {
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 32,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      await scope.resources.writeBuffer(
        uniform,
        Float32List.fromList([
          options.thresholdLevel,
          options.thresholdRange,
          options.ghostAmount,
          options.haloAmount,
          options.chromaticAberration,
          options.intensity,
          width.toDouble(),
          height.toDouble(),
        ]),
      );
      final stages = <ScreenEffect>[], programs = <String, ShaderProgram>{};
      Future<GpuResource<Texture>> target(int w, int h) =>
          scope.resources.createTexture(
            TextureDescriptor(
              width: w,
              height: h,
              format: TextureFormat.rgba16Float,
              usage: {
                TextureUsage.sampled,
                TextureUsage.renderAttachment,
                TextureUsage.copySource,
              },
            ),
          );
      Future<void> pass(
        String source, {
        GpuResource<Texture>? output,
        GpuResource<Texture>? input,
        GpuResource<Texture>? high,
        bool lensUniform = false,
      }) async {
        final program = programs[source] ??= await scope.shaders.compile(
          ShaderSource.wgsl(source, label: 'Lens stage ${stages.length}'),
        );
        stages.add(
          await scope.materials.compileEffect(
            PostProcessDescriptor(
              program: program,
              target: output,
              bindings: ShaderBindings([
                if (input != null) TextureBinding.sampled(0, input, group: 1),
                if (high != null) TextureBinding.sampled(1, high, group: 1),
                if (lensUniform) BufferBinding.uniform(0, uniform, group: 2),
              ]),
            ),
          ),
        );
      }

      final threshold = await target(width, height);
      await pass(lensThresholdWgsl, output: threshold, lensUniform: true);
      var current = threshold, w = width, h = height;
      final down = <GpuResource<Texture>>[];
      for (var i = 0; i < 8; i++) {
        w = math.max(1, (w / 2).round());
        h = math.max(1, (h / 2).round());
        final output = await target(w, h);
        await pass(
          blurShader('lensDown', const [], const [], .85, screen: true),
          output: output,
          input: current,
        );
        down.add(output);
        current = output;
      }
      for (var i = 6; i >= 0; i--) {
        final extent = down[i].descriptor as TextureDescriptor;
        final output = await target(extent.width, extent.height);
        await pass(
          blurShader('lensUp', const [], const [], .85, screen: true),
          output: output,
          input: current,
          high: down[i],
        );
        current = output;
      }
      final bloom = current;
      current = threshold;
      for (final kernel in [0, 1, 1]) {
        final output = await target(
          math.max(1, (width / 2).round()),
          math.max(1, (height / 2).round()),
        );
        await pass(
          lensKawaseWgsl(kernel),
          output: output,
          input: current,
          lensUniform: true,
        );
        current = output;
      }
      final blurred = await target(width, height);
      await pass(
        lensCopyWgsl,
        output: blurred,
        input: current,
        lensUniform: true,
      );
      final features = await target(width, height);
      await pass(
        lensFeaturesWgsl,
        output: features,
        input: blurred,
        lensUniform: true,
      );
      await pass(
        lensCompositeWgsl,
        input: bloom,
        high: features,
        lensUniform: true,
      );
      return LensFlareEffect._(scope, stages, threshold, bloom, features);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}

/// Keeps the scene slots stable across a fully prepared lens replacement.
final class LensFlareAttachment {
  final List<EffectRegistration> _slots;
  LensFlareAttachment._(this._slots);
  bool get isDisposed => _slots.first.isDisposed;
  void replace(LensFlareEffect candidate) {
    if (isDisposed) throw StateError('Lens attachment has closed.');
    candidate._validate();
    for (var i = 0; i < _slots.length; i++) {
      _slots[i].replace(candidate.stages[i]);
    }
  }

  void dispose() {
    for (final slot in _slots) {
      slot.dispose();
    }
  }
}
