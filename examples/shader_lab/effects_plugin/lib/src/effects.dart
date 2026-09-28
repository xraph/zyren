import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'shaders.dart';

enum UnsupportedEffects { reject, bypass }

enum EffectsAvailability { detached, supported, unsupported }

/// Spatial effects in linear light. Exposure uses stops; zero leaves it unchanged.
final class EffectsOptions {
  final bool enabled;
  final double exposure, saturation, vignette;
  EffectsOptions({
    this.enabled = true,
    this.exposure = 0,
    this.saturation = 1,
    this.vignette = .45,
  }) {
    _range(exposure, -2, 2, 'exposure');
    _range(saturation, 0, 2, 'saturation');
    _range(vignette, 0, 1, 'vignette');
  }
  static void _range(double value, double min, double max, String name) {
    if (!value.isFinite || value < min || value > max) {
      throw ArgumentError.value(value, name, 'Expected [$min, $max].');
    }
  }

  EffectsOptions copyWith({
    bool? enabled,
    double? exposure,
    double? saturation,
    double? vignette,
  }) => EffectsOptions(
    enabled: enabled ?? this.enabled,
    exposure: exposure ?? this.exposure,
    saturation: saturation ?? this.saturation,
    vignette: vignette ?? this.vignette,
  );
}

final class EffectsState {
  final EffectsAvailability availability;
  final Set<RenderFeature> missingFeatures;
  final PhysicalSize? size;
  final int graphBuilds;
  EffectsState({
    required this.availability,
    Set<RenderFeature> missingFeatures = const {},
    this.size,
    this.graphBuilds = 0,
  }) : missingFeatures = Set.unmodifiable(missingFeatures);
}

abstract interface class EffectsControls {
  EffectsOptions get options;
  set options(EffectsOptions value);
  EffectsState get state;
}

const effectsControls = ServiceKey<EffectsControls>(
  'shader-lab.effects.controls',
);

/// One instance per view. Install before the controller's first attachment.
final class EffectsPlugin extends ScenePlugin implements EffectsControls {
  static const pluginId = 'shader-lab.effects';
  static const features = {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.renderGraphs,
    RenderFeature.frameGraphs,
  };
  final UnsupportedEffects unsupported;
  EffectsOptions _options;
  EffectsOptions? _uploaded;
  PluginContext? _context;
  FrameGraphBinding? _binding;
  ShaderProgram? _program;
  GpuResource<Buffer>? _parameters;
  EffectsState _state = EffectsState(
    availability: EffectsAvailability.detached,
  );
  EffectsPlugin({
    EffectsOptions? options,
    this.unsupported = UnsupportedEffects.reject,
  }) : _options = options ?? EffectsOptions();

  @override
  String get id => pluginId;
  @override
  Set<RenderFeature> get requiredFeatures =>
      unsupported == UnsupportedEffects.reject ? features : const {};
  @override
  EffectsOptions get options => _options;
  @override
  set options(EffectsOptions value) {
    if (identical(value, _options)) return;
    _options = value;
    final context = _context;
    if (context != null && !context.scope.isClosed) context.invalidate();
  }

  @override
  EffectsState get state => _state;

  @override
  Future<void> attach(PluginContext context) async {
    _context = context;
    final missing = features.difference(context.capabilities.features);
    _state = EffectsState(
      availability: missing.isEmpty
          ? EffectsAvailability.supported
          : EffectsAvailability.unsupported,
      missingFeatures: missing,
    );
    context.provide(effectsControls, this);
    if (missing.isNotEmpty) return;
    _binding = context.frameGraph;
    _program = await context.shaders.compile(
      ShaderSource.wgsl(effectsWgsl, label: 'shader-lab.effects.wgsl'),
    );
    _parameters = await context.resources.createBuffer(
      BufferDescriptor(
        label: 'effects parameters',
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    if (_state.availability != EffectsAvailability.supported) return;
    final options = _options;
    if (!options.enabled) {
      _binding!.graph = null;
      return;
    }
    if (!identical(_uploaded, options)) {
      await context.resources.writeBuffer(
        _parameters!,
        Float32List.fromList([
          math.pow(2, options.exposure).toDouble(),
          options.saturation,
          options.vignette,
          0,
        ]),
      );
      _uploaded = options;
    }
    if (_state.size?.width != frame.width ||
        _state.size?.height != frame.height) {
      await _resize(context, frame);
    }
    _binding!.graph = context.graphs.active;
  }

  Future<void> _resize(PluginContext context, FrameInfo frame) async {
    final candidate = context.resources.createChild(label: 'effects resize');
    try {
      Future<GpuResource<Texture>> texture(String label) =>
          candidate.createTexture(
            TextureDescriptor(
              label: label,
              width: frame.width,
              height: frame.height,
              usage: {TextureUsage.renderAttachment, TextureUsage.sampled},
            ),
          );
      final scene = await texture('effects scene');
      final graded = await texture('effects color');
      final output = await texture('effects output');
      RenderPassDescriptor pass(
        String name,
        String fragment,
        GpuResource<Texture> input,
        GpuResource<Texture> target,
      ) => RenderPassDescriptor(
        name: name,
        program: _program!,
        fragmentEntryPoint: fragment,
        color: ColorAttachment(target),
        bindings: ShaderBindings([
          TextureBinding.sampled(0, input),
          BufferBinding.uniform(1, _parameters!),
        ]),
        reads: [input, _parameters!],
        writes: [target],
      );
      final graph = await context.graphs.compile(
        GraphDescription(
          label: 'shader-lab.effects',
          sceneColor: scene,
          output: output,
          inputs: [_parameters!],
          passes: [
            pass('effects.color', 'grade', scene, graded),
            pass('effects.vignette', 'vignette', graded, output),
          ],
        ),
      );
      _binding!.graph = graph;
      _state = EffectsState(
        availability: EffectsAvailability.supported,
        size: PhysicalSize(frame.width, frame.height),
        graphBuilds: _state.graphBuilds + 1,
      );
    } finally {
      // The compiled graph retains textures; failed candidates have no owner.
      await candidate.close();
    }
  }

  @override
  void detach(PluginContext context) {
    _context = null;
    _binding = null;
    _program = null;
    _parameters = null;
    _uploaded = null;
    _state = EffectsState(availability: EffectsAvailability.detached);
  }
}
