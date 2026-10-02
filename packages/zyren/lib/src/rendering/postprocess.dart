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
  output: vec4<f32>, // tone map, sRGB output, spatial AA, encoded input
  depth: vec4<f32>, // reversed depth, reserved
};
@group(0) @binding(0) var sceneColor: texture_2d<f32>;
@group(0) @binding(1) var sceneDepth: texture_depth_2d;
@group(0) @binding(2) var historyColor: texture_2d<f32>;
@group(0) @binding(3) var<uniform> screen: ScreenUniforms;
// UV uses the top-left image origin. The result is relative to the camera.
fn scenePosition(uv: vec2<f32>, depth: f32) -> vec3<f32> {
  let ndc = uv * vec2<f32>(2., -2.) + vec2<f32>(-1., 1.);
  let point = screen.inverseViewProjection * vec4<f32>(ndc, depth, 1.);
  return point.xyz / point.w;
}
fn sceneNearDepth() -> f32 { return select(0., 1., screen.depth.x > .5); }
fn sceneDepthIsBackground(depth: f32) -> bool {
  return select(depth >= 1., depth <= 0., screen.depth.x > .5);
}
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

enum SpatialAntialiasing { none, fxaa }

/// A normalized HDR bloom pyramid. Threshold is linear, before exposure.
/// Bloom preserves scene alpha, so transparent backgrounds clip its halo.
final class BloomSettings {
  final double intensity, threshold, softKnee, scatter;
  final int levels;
  BloomSettings({
    this.intensity = .15,
    this.threshold = 1,
    this.softKnee = .5,
    this.scatter = .7,
    this.levels = 5,
  }) {
    if (!intensity.isFinite ||
        intensity < 0 ||
        intensity > 16 ||
        !threshold.isFinite ||
        threshold < 0 ||
        threshold > 65504 ||
        !softKnee.isFinite ||
        softKnee < 0 ||
        softKnee > 1 ||
        !scatter.isFinite ||
        scatter < 0 ||
        scatter > 1 ||
        levels < 1 ||
        levels > 6) {
      throw ArgumentError('Invalid bloom parameters.');
    }
  }
}

/// Immutable per-view render configuration. Increment [historyEpoch] for a cut
/// or a discontinuous parameter edit. Camera/projection edits also invalidate.
final class RenderSettings {
  final List<ScreenEffect> effects;
  final ToneMapping toneMapping;
  final SpatialAntialiasing spatialAntialiasing;
  final BloomSettings? bloom;
  final double exposure, backgroundAlpha;
  final int historyEpoch, sampleCount;
  final bool hdr;
  final VolumeEnvironmentMap? environment;
  RenderSettings({
    Iterable<ScreenEffect> effects = const [],
    this.toneMapping = ToneMapping.none,
    this.spatialAntialiasing = SpatialAntialiasing.none,
    this.bloom,
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
    SpatialAntialiasing? spatialAntialiasing,
    BloomSettings? bloom,
    bool clearBloom = false,
    double? exposure,
    double? backgroundAlpha,
    int? historyEpoch,
    bool? hdr,
    int? sampleCount,
    VolumeEnvironmentMap? environment,
  }) => RenderSettings(
    effects: effects ?? this.effects,
    toneMapping: toneMapping ?? this.toneMapping,
    spatialAntialiasing: spatialAntialiasing ?? this.spatialAntialiasing,
    bloom: clearBloom ? null : bloom ?? this.bloom,
    exposure: exposure ?? this.exposure,
    backgroundAlpha: backgroundAlpha ?? this.backgroundAlpha,
    historyEpoch: historyEpoch ?? this.historyEpoch,
    hdr: hdr ?? this.hdr,
    sampleCount: sampleCount ?? this.sampleCount,
    environment: environment ?? this.environment,
  );
  bool get enabled =>
      spatialAntialiasing != SpatialAntialiasing.none ||
      bloom != null ||
      sampleCount != 1 ||
      environment != null ||
      hdr ||
      effects.isNotEmpty ||
      toneMapping != ToneMapping.none ||
      exposure != 1 ||
      backgroundAlpha != 1 ||
      historyEpoch != 0;
}
