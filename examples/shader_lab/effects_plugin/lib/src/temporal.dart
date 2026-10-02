import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'effects.dart';

/// A temporal blend that demonstrates frame history. This does not reproject
/// motion or replace temporal antialiasing. Retention is the previous-frame weight.
final class TemporalBlendPlugin extends ScenePlugin {
  static const pluginId = 'shader-lab.temporal';
  final UnsupportedEffects unsupported;
  final Set<String> after;
  bool _enabled;
  double _retention;
  double? _uploaded;
  PluginContext? _context;
  GraphRegistration? _registration;
  Registration? _demand;
  GpuResource<Buffer>? _parameters;
  bool _supported = false;
  TemporalBlendPlugin({
    bool enabled = false,
    double retention = .8,
    this.unsupported = UnsupportedEffects.reject,
    Set<String> after = const {},
  }) : _enabled = enabled,
       _retention = _valid(retention),
       after = Set.unmodifiable(after);
  static double _valid(double value) {
    if (!value.isFinite || value < 0 || value >= 1) {
      throw ArgumentError.value(value, 'retention', 'Expected [0, 1).');
    }
    return value;
  }

  @override
  String get id => pluginId;
  @override
  Set<RenderFeature> get requiredFeatures =>
      unsupported == UnsupportedEffects.reject
      ? EffectsPlugin.features
      : const {};
  bool get enabled => _enabled;
  set enabled(bool value) {
    _enabled = value;
    _invalidate();
  }

  double get retention => _retention;
  set retention(double value) {
    _retention = _valid(value);
    _invalidate();
  }

  void _invalidate() {
    final context = _context;
    if (context != null && !context.scope.isClosed) context.invalidate();
  }

  void reset() {
    final context = _context;
    if (context != null && !context.scope.isClosed && _supported) {
      context.graph.invalidateHistory();
    }
  }

  int get historyFrames =>
      _context != null && !_context!.scope.isClosed && _supported
      ? _context!.graph.state.historyFrames
      : 0;
  @override
  Future<void> attach(PluginContext context) async {
    _context = context;
    _supported = EffectsPlugin.features
        .difference(context.capabilities.features)
        .isEmpty;
    if (!_supported) return;
    _parameters = await context.resources.createBuffer(
      BufferDescriptor(
        label: 'history blend retention',
        size: 16,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    final shader = await context.shaders.compile(
      ShaderSource.wgsl('''
${TextureHistory.wgsl}
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var previous: texture_2d<f32>;
@group(0) @binding(2) var<uniform> history: TextureHistoryState;
@group(0) @binding(3) var<uniform> parameters: vec4<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) p: vec4<f32>) -> @location(0) vec4<f32> {
  let xy = vec2<i32>(p.xy);
  let current = textureLoad(source, xy, 0);
  if (history.validFrames == 0u) { return current; }
  let old = textureLoad(previous, xy, 0);
  let alpha = mix(current.a, old.a, parameters.x);
  let associated = mix(current.rgb * current.a, old.rgb * old.a, parameters.x);
  return vec4(select(vec3(0.), associated / max(alpha, 1e-8), alpha > 0.), alpha);
}
''', label: 'shader-lab.temporal.wgsl'),
    );
    _registration = context.graph.addEffect(
      name: id,
      after: after,
      enabled: _enabled,
      build: (frame) async {
        final history = await frame.createHistory(label: 'temporal blend');
        return GraphEffect(
          output: history.current,
          inputs: [_parameters!],
          passes: [
            RenderPassDescriptor(
              name: 'temporal.blend',
              program: shader,
              color: ColorAttachment(history.current),
              bindings: ShaderBindings([
                TextureBinding.sampled(0, frame.input),
                TextureBinding.sampled(1, history.previous),
                BufferBinding.uniform(2, history.uniforms),
                BufferBinding.uniform(3, _parameters!),
              ]),
              reads: [
                frame.input,
                history.previous,
                history.uniforms,
                _parameters!,
              ],
              writes: [history.current],
            ),
          ],
        );
      },
    );
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    if (!_supported) return;
    _registration!.enabled = _enabled;
    if (!_enabled) {
      _demand?.dispose();
      _demand = null;
      return;
    }
    _demand ??= context.acquireFrameDemand();
    final value = _retention;
    if (_uploaded != value) {
      await context.resources.writeBuffer(
        _parameters!,
        Float32List.fromList([value, 0, 0, 0]),
      );
      _uploaded = value;
    }
  }

  @override
  void detach(PluginContext context) {
    _demand?.dispose();
    _demand = null;
    _context = null;
    _registration = null;
    _parameters = null;
    _uploaded = null;
    _supported = false;
  }
}
