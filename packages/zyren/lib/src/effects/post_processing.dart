import 'dart:typed_data';
import '../plugins/engine.dart';
import '../rendering/capabilities.dart';
import '../resources/buffer.dart';
import '../resources/resource_scope.dart';
import '../resources/texture.dart';
import 'shaders.dart';

/// Linear-light bloom. Radius is the blur spacing in half-resolution pixels.
final class BloomOptions {
  final double threshold, knee, intensity, radius;
  BloomOptions({
    this.threshold = 1,
    this.knee = .5,
    this.intensity = .6,
    this.radius = 1,
  }) {
    for (final (value, maximum, name) in [
      (threshold, 65504.0, 'threshold'),
      (knee, 1.0, 'knee'),
      (intensity, 16.0, 'intensity'),
      (radius, 4.0, 'radius'),
    ]) {
      if (!value.isFinite ||
          value < 0 ||
          value > maximum ||
          (name == 'radius' && value < .5)) {
        throw ArgumentError.value(
          value,
          name,
          'Outside the supported bloom range.',
        );
      }
    }
  }
}

/// HDR bloom and optional edge-aware spatial filtering through the public graph.
/// Use one instance per view with ColorPipeline. No temporal history is retained.
final class PostProcessing extends ScenePlugin {
  BloomOptions? _bloom, _uploaded;
  bool _antialias;
  final int maxIntermediateBytes;
  final Set<String> after;
  @override
  final String id;
  PluginContext? _context;
  GraphRegistration? _registration;
  ShaderProgram? _program;
  GpuResource<Buffer>? _parameters;
  PostProcessing({
    BloomOptions? bloom,
    bool antialias = false,
    this.maxIntermediateBytes = 64 * 1024 * 1024,
    this.id = 'zyren.post-processing',
    Set<String> after = const {},
  }) : _bloom = bloom,
       _antialias = antialias,
       after = Set.unmodifiable(after) {
    if (maxIntermediateBytes < 1) {
      throw ArgumentError.value(maxIntermediateBytes, 'maxIntermediateBytes');
    }
  }
  BloomOptions? get bloom => _bloom;
  set bloom(BloomOptions? value) {
    final layoutChanged = (_bloom == null) != (value == null);
    _bloom = value;
    if (layoutChanged) _registration?.invalidate();
    _context?.invalidate();
  }

  bool get antialias => _antialias;
  set antialias(bool value) {
    if (value == _antialias) return;
    _antialias = value;
    _registration?.invalidate();
  }

  @override
  Set<RenderFeature> get requiredFeatures => const {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.renderGraphs,
    RenderFeature.frameGraphs,
    RenderFeature.hdrColor,
  };
  @override
  Future<void> attach(PluginContext context) async {
    _context = context;
    _program = await context.shaders.compile(
      ShaderSource.wgsl(postProcessingWgsl, label: id),
    );
    _parameters = await context.resources.createBuffer(
      BufferDescriptor(
        label: '$id parameters',
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    _registration = context.graph.addEffect(
      name: id,
      after: after,
      build: _build,
      enabled: _bloom != null || _antialias,
    );
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    _registration!.enabled = _bloom != null || _antialias;
    final value = _bloom;
    if (value != null && !identical(value, _uploaded)) {
      await context.resources.writeBuffer(
        _parameters!,
        Float32List.fromList([
          value.threshold,
          value.knee,
          value.intensity,
          value.radius,
        ]),
      );
      _uploaded = value;
    }
  }

  Future<GraphEffect> _build(EffectBuildContext frame) async {
    final descriptor = frame.input.descriptor as TextureDescriptor;
    if (descriptor.format != TextureFormat.rgba16Float) {
      throw StateError('PostProcessing requires ColorPipeline on this view.');
    }
    final w = frame.size.width, h = frame.size.height;
    final halfW = (w + 1) ~/ 2, halfH = (h + 1) ~/ 2;
    final bytes =
        ((_bloom == null ? 0 : halfW * halfH * 3 + w * h) +
            (_antialias ? w * h : 0)) *
        8;
    if (bytes > maxIntermediateBytes) {
      throw ResourceException(
        ResourceErrorCode.budgetExceeded,
        'PostProcessing needs $bytes intermediate bytes; the limit is $maxIntermediateBytes.',
      );
    }
    final passes = <PassDescriptor>[];
    GpuResource<Texture> input = frame.input;
    RenderPassDescriptor pass(
      String entry,
      GpuResource<Texture> source,
      GpuResource<Texture> output, {
      GpuResource<Texture>? glow,
    }) => RenderPassDescriptor(
      name: '$id.$entry',
      program: _program!,
      fragmentEntryPoint: entry,
      color: ColorAttachment(output),
      bindings: ShaderBindings([
        TextureBinding.sampled(0, source),
        if (entry != 'antialias') BufferBinding.uniform(1, _parameters!),
        if (glow != null) TextureBinding.sampled(2, glow),
      ]),
      reads: [source, if (entry != 'antialias') _parameters!, ?glow],
      writes: [output],
    );
    if (_bloom != null) {
      Future<GpuResource<Texture>> half(String label) =>
          frame.resources.createTexture(
            TextureDescriptor(
              label: '$id $label',
              width: halfW,
              height: halfH,
              format: descriptor.format,
              usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
            ),
          );
      final bright = await half('bright');
      final horizontal = await half('horizontal');
      final blurred = await half('blurred');
      final output = await frame.createColorTexture(label: '$id bloom');
      passes.addAll([
        pass('extract', input, bright),
        pass('horizontal', bright, horizontal),
        pass('vertical', horizontal, blurred),
        pass('composite', input, output, glow: blurred),
      ]);
      input = output;
    }
    if (_antialias) {
      final output = await frame.createColorTexture(label: '$id antialias');
      passes.add(pass('antialias', input, output));
      input = output;
    }
    return GraphEffect(output: input, passes: passes, inputs: [_parameters!]);
  }

  @override
  void detach(PluginContext context) {
    _context = null;
    _registration = null;
    _program = null;
    _parameters = null;
    _uploaded = null;
  }
}
