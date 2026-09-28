part of '../resources/resource_scope.dart';

/// A fullscreen stage reading the preceding linear, premultiplied HDR result.
final class PostProcessDescriptor extends MeshShaderDescriptor {
  PostProcessDescriptor({
    required super.program,
    super.bindings,
    super.label = 'screen effect',
    super.vertexEntryPoint,
    super.fragmentEntryPoint,
  });

  static const interfaceWgsl = '''
struct ScreenUniforms {
  inverseViewProjection: mat4x4<f32>,
  viewport: vec4<f32>, // width, height, history valid, exposure
  output: vec4<f32>, // tone map, reserved
};
@group(0) @binding(0) var sceneColor: texture_2d<f32>;
@group(0) @binding(1) var sceneDepth: texture_depth_2d;
@group(0) @binding(2) var historyColor: texture_2d<f32>;
@group(0) @binding(3) var<uniform> screen: ScreenUniforms;
struct ScreenVertex {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
};
@vertex fn vertex(@builtin(vertex_index) index: u32) -> ScreenVertex {
  let uv = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u));
  var v: ScreenVertex;
  v.position = vec4<f32>(uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
  v.uv = uv;
  return v;
}
''';
}

final class ScreenEffect {
  final MeshShader _shader;
  ScreenEffect._(this._shader);
  bool get isClosed => _shader.isClosed;
  Uint8List encodeForDevice(MaterialDevice device) =>
      _shader.encodeForDevice(device);
}

enum ToneMapping { none, reinhard, aces }

/// Immutable per-view render configuration. Increment [historyEpoch] for a cut
/// or a discontinuous parameter edit. Camera/projection edits also invalidate.
final class RenderSettings {
  final List<ScreenEffect> effects;
  final ToneMapping toneMapping;
  final double exposure, backgroundAlpha;
  final int historyEpoch, sampleCount;
  final bool hdr;
  final EnvironmentMap? environment;
  RenderSettings({
    Iterable<ScreenEffect> effects = const [],
    this.toneMapping = ToneMapping.none,
    this.exposure = 1,
    this.backgroundAlpha = 1,
    this.historyEpoch = 0,
    this.hdr = false,
    this.sampleCount = 1,
    this.environment,
  }) : effects = List.unmodifiable(effects) {
    if (!{1, 4}.contains(sampleCount) ||
        !exposure.isFinite ||
        exposure < 0 ||
        exposure > 65504 ||
        !backgroundAlpha.isFinite ||
        backgroundAlpha < 0 ||
        backgroundAlpha > 1 ||
        historyEpoch < 0 ||
        historyEpoch > 0xffffffff ||
        this.effects.length > 8) {
      throw ArgumentError(
        'Invalid render settings or more than eight effects.',
      );
    }
  }
  RenderSettings copyWith({
    Iterable<ScreenEffect>? effects,
    ToneMapping? toneMapping,
    double? exposure,
    double? backgroundAlpha,
    int? historyEpoch,
    bool? hdr,
    int? sampleCount,
    EnvironmentMap? environment,
  }) => RenderSettings(
    effects: effects ?? this.effects,
    toneMapping: toneMapping ?? this.toneMapping,
    exposure: exposure ?? this.exposure,
    backgroundAlpha: backgroundAlpha ?? this.backgroundAlpha,
    historyEpoch: historyEpoch ?? this.historyEpoch,
    hdr: hdr ?? this.hdr,
    sampleCount: sampleCount ?? this.sampleCount,
    environment: environment ?? this.environment,
  );
  bool get enabled =>
      sampleCount != 1 ||
      environment != null ||
      hdr ||
      effects.isNotEmpty ||
      toneMapping != ToneMapping.none ||
      exposure != 1 ||
      backgroundAlpha != 1 ||
      historyEpoch != 0;
}
