part of '../resources/resource_scope.dart';

/// Selects the color space and position of a fullscreen effect.
enum PostProcessStage {
  /// Linear HDR, before bloom, exposure and tone mapping.
  hdr,

  /// Encoded sRGB after tone mapping, before output antialiasing.
  display,
}

/// A fullscreen stage reading the preceding premultiplied result in [stage].
/// History always contains the HDR result, including in display effects.
/// User groups may write storage textures from the fragment stage. Later effects
/// can sample those outputs in the same frame. Allocate the desired dimensions,
/// write every texel you consume, and retain the effect while its outputs are used.
/// Binding a texture for both sampling and writing in one stage is rejected.
final class PostProcessDescriptor extends MeshShaderDescriptor {
  final PostProcessStage stage;

  /// Optional RGBA16F render attachment. Its extent sets the draw resolution.
  /// The main color chain remains unchanged; later stages may sample this map.
  /// Screen uniforms retain the scene viewport; vertex UV spans this target.
  final GpuResource<Texture>? target;
  PostProcessDescriptor({
    this.stage = PostProcessStage.hdr,
    this.target,
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
  PostProcessStage get stage =>
      (_shader.descriptor as PostProcessDescriptor).stage;
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

/// Bounds screen-space work per receiving fragment. There is no temporal history.
enum ScreenSpaceQuality { low, medium, high }

/// Optional indirect lighting from the current opaque view.
/// You get full-resolution, single-sample inputs even when the main view uses MSAA.
/// Transparent and transmissive surfaces do not receive these effects.
final class ScreenSpaceLighting {
  final bool ambientOcclusion, reflections;
  final ScreenSpaceQuality quality;
  final double radius, intensity, bias, maxDistance, thickness, maxRoughness;
  ScreenSpaceLighting({
    this.ambientOcclusion = false,
    this.reflections = false,
    this.quality = ScreenSpaceQuality.medium,
    this.radius = .5,
    this.intensity = 1,
    this.bias = .02,
    this.maxDistance = 20,
    this.thickness = .2,
    this.maxRoughness = .6,
  }) {
    if (!radius.isFinite ||
        radius <= 0 ||
        radius > 1000 ||
        !intensity.isFinite ||
        intensity < 0 ||
        intensity > 1 ||
        !bias.isFinite ||
        bias < 0 ||
        bias > 1 ||
        !maxDistance.isFinite ||
        maxDistance <= 0 ||
        maxDistance > 10000 ||
        !thickness.isFinite ||
        thickness <= 0 ||
        thickness > 100 ||
        !maxRoughness.isFinite ||
        maxRoughness <= 0 ||
        maxRoughness > 1) {
      throw ArgumentError('Invalid screen-space lighting parameters.');
    }
  }
  bool get enabled => ambientOcclusion || reflections;
  int get aoSamples => [8, 12, 16][quality.index];
  int get reflectionSteps => [16, 32, 64][quality.index];
  Map<String, Object> toPacket() => {
    'ao': ambientOcclusion,
    'reflections': reflections,
    'quality': quality.index,
    'radius': radius,
    'intensity': intensity,
    'bias': bias,
    'max_distance': maxDistance,
    'thickness': thickness,
    'max_roughness': maxRoughness,
  };
}

/// Immutable per-view render configuration. Increment [historyEpoch] for a cut
/// or a discontinuous parameter edit. Camera/projection edits also invalidate.
final class RenderSettings {
  final List<ScreenEffect> effects;
  final ToneMapping toneMapping;
  final SpatialAntialiasing spatialAntialiasing;
  final BloomSettings? bloom;
  final ScreenSpaceLighting? screenSpaceLighting;
  final double exposure, backgroundAlpha;

  /// Linear resolution of the opaque color/depth capture, in 0.5..1. This
  /// affects transmission and mesh scene inputs, not the main view size.
  final double opaqueCaptureScale;
  final int historyEpoch, sampleCount;
  final bool hdr;
  final VolumeEnvironmentMap? environment;
  RenderSettings({
    Iterable<ScreenEffect> effects = const [],
    this.toneMapping = ToneMapping.none,
    this.spatialAntialiasing = SpatialAntialiasing.none,
    this.bloom,
    this.screenSpaceLighting,
    this.exposure = 1,
    this.backgroundAlpha = 1,
    this.opaqueCaptureScale = 1,
    this.historyEpoch = 0,
    this.hdr = false,
    this.sampleCount = 1,
    this.environment,
  }) : effects = List.unmodifiable(effects) {
    if (!opaqueCaptureScale.isFinite ||
        opaqueCaptureScale < .5 ||
        opaqueCaptureScale > 1 ||
        !{1, 4}.contains(sampleCount) ||
        !exposure.isFinite ||
        exposure < 0 ||
        exposure > 65504 ||
        !backgroundAlpha.isFinite ||
        backgroundAlpha < 0 ||
        backgroundAlpha > 1 ||
        historyEpoch < 0 ||
        historyEpoch > 0xffffffff ||
        this.effects.length > 32) {
      throw ArgumentError('Invalid render settings or more than 32 effects.');
    }
  }
  RenderSettings copyWith({
    Iterable<ScreenEffect>? effects,
    ToneMapping? toneMapping,
    SpatialAntialiasing? spatialAntialiasing,
    BloomSettings? bloom,
    bool clearBloom = false,
    ScreenSpaceLighting? screenSpaceLighting,
    bool clearScreenSpaceLighting = false,
    double? exposure,
    double? backgroundAlpha,
    double? opaqueCaptureScale,
    int? historyEpoch,
    bool? hdr,
    int? sampleCount,
    VolumeEnvironmentMap? environment,
  }) => RenderSettings(
    effects: effects ?? this.effects,
    toneMapping: toneMapping ?? this.toneMapping,
    spatialAntialiasing: spatialAntialiasing ?? this.spatialAntialiasing,
    bloom: clearBloom ? null : bloom ?? this.bloom,
    screenSpaceLighting: clearScreenSpaceLighting
        ? null
        : screenSpaceLighting ?? this.screenSpaceLighting,
    exposure: exposure ?? this.exposure,
    backgroundAlpha: backgroundAlpha ?? this.backgroundAlpha,
    opaqueCaptureScale: opaqueCaptureScale ?? this.opaqueCaptureScale,
    historyEpoch: historyEpoch ?? this.historyEpoch,
    hdr: hdr ?? this.hdr,
    sampleCount: sampleCount ?? this.sampleCount,
    environment: environment ?? this.environment,
  );
  bool get enabled =>
      spatialAntialiasing != SpatialAntialiasing.none ||
      bloom != null ||
      (screenSpaceLighting?.enabled ?? false) ||
      sampleCount != 1 ||
      environment != null ||
      hdr ||
      effects.isNotEmpty ||
      toneMapping != ToneMapping.none ||
      exposure != 1 ||
      backgroundAlpha != 1 ||
      historyEpoch != 0;
}
