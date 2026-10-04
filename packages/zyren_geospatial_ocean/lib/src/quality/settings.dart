import 'package:zyren/zyren.dart';
import '../rendering/reflections.dart';
import '../rendering/underwater.dart';
import '../rendering/wave_render_data.dart';
import '../surface/selector.dart';

/// Starting work limits for qualification. Admission can reject a profile when
/// all charts, views and transition resources exceed its allowance.
enum OceanRenderQuality {
  low(64, 2, 96, 65536, .5, 0, 0, 0, 32, 0),
  medium(128, 3, 192, 131072, .5, 16, 12, 2048, 64, 64),
  high(256, 4, 384, 262144, .75, 32, 24, 8192, 128, 128),
  ultra(512, 4, 768, 524288, 1, 64, 48, 32768, 256, 256);

  final int _fft,
      _bands,
      _patches,
      _vertices,
      _ssr,
      _shafts,
      _spray,
      _mib,
      _caustics;
  final double _scale;
  const OceanRenderQuality(
    this._fft,
    this._bands,
    this._patches,
    this._vertices,
    this._scale,
    this._ssr,
    this._shafts,
    this._spray,
    this._mib,
    this._caustics,
  );
  OceanQualitySettings get settings => OceanQualitySettings(
    fftResolution: _fft,
    maxBands: _bands,
    maxPatches: _patches,
    maxVertices: _vertices,
    sceneInputScale: _scale,
    ssrSteps: _ssr,
    shaftSteps: _shafts,
    sprayParticleCap: _spray,
    gpuBudgetBytes: _mib * 1024 * 1024,
    causticResolution: _caustics,
  );
}

/// Independent visual work bounds. This value contains no density, sea level,
/// canonical spectrum, physical query policy or simulation clock settings.
final class OceanQualitySettings {
  final int fftResolution,
      maxBands,
      maxPatches,
      maxVertices,
      ssrSteps,
      shaftSteps,
      sprayParticleCap,
      gpuBudgetBytes,
      causticResolution,
      segments;
  final double sceneInputScale, maxScreenError;
  OceanQualitySettings({
    required this.fftResolution,
    required this.maxBands,
    required this.maxPatches,
    required this.maxVertices,
    required this.sceneInputScale,
    required this.ssrSteps,
    required this.shaftSteps,
    required this.sprayParticleCap,
    required this.gpuBudgetBytes,
    required this.causticResolution,
    this.segments = 16,
    this.maxScreenError = 2,
  }) {
    OceanWaveRenderData.mipTexels(fftResolution);
    if (maxBands < 1 ||
        maxBands > 8 ||
        !sceneInputScale.isFinite ||
        sceneInputScale < .5 ||
        sceneInputScale > 1 ||
        ssrSteps < 0 ||
        ssrSteps > 64 ||
        sprayParticleCap < 0 ||
        sprayParticleCap > 65536 ||
        gpuBudgetBytes < 1 ||
        gpuBudgetBytes > 1 << 30) {
      throw ArgumentError('Invalid ocean quality work limits.');
    }
    // Reuse the actual consumer validations so accepted settings are executable.
    lod;
    underwater;
  }
  OceanLodSettings get lod => OceanLodSettings(
    maxScreenError: maxScreenError,
    maxPatches: maxPatches,
    maxVertices: maxVertices,
    segments: segments,
  );
  OceanReflectionSettings get reflections => OceanReflectionSettings(
    mode: ssrSteps == 0
        ? OceanReflectionMode.environment
        : OceanReflectionMode.screenSpace,
    stepLimit: ssrSteps == 0 ? 1 : ssrSteps,
  );
  OceanUnderwaterSettings get underwater => OceanUnderwaterSettings(
    shaftSteps: shaftSteps,
    causticResolution: causticResolution,
  );
  RenderSettings applyTo(RenderSettings source) =>
      source.copyWith(opaqueCaptureScale: sceneInputScale);

  /// A modified value has no preset label unless every saved work limit matches.
  OceanRenderQuality? get preset {
    final actual = toJson();
    for (final profile in OceanRenderQuality.values) {
      final expected = profile.settings.toJson();
      if (actual.entries.every((e) => expected[e.key] == e.value)) {
        return profile;
      }
    }
    return null;
  }

  OceanQualitySettings copyWith({
    int? fftResolution,
    int? maxBands,
    int? maxPatches,
    int? maxVertices,
    double? sceneInputScale,
    int? ssrSteps,
    int? shaftSteps,
    int? sprayParticleCap,
    int? gpuBudgetBytes,
    int? causticResolution,
    int? segments,
    double? maxScreenError,
  }) => OceanQualitySettings(
    fftResolution: fftResolution ?? this.fftResolution,
    maxBands: maxBands ?? this.maxBands,
    maxPatches: maxPatches ?? this.maxPatches,
    maxVertices: maxVertices ?? this.maxVertices,
    sceneInputScale: sceneInputScale ?? this.sceneInputScale,
    ssrSteps: ssrSteps ?? this.ssrSteps,
    shaftSteps: shaftSteps ?? this.shaftSteps,
    sprayParticleCap: sprayParticleCap ?? this.sprayParticleCap,
    gpuBudgetBytes: gpuBudgetBytes ?? this.gpuBudgetBytes,
    causticResolution: causticResolution ?? this.causticResolution,
    segments: segments ?? this.segments,
    maxScreenError: maxScreenError ?? this.maxScreenError,
  );
  Map<String, Object> toJson() => {
    'version': 1,
    'fftResolution': fftResolution,
    'maxBands': maxBands,
    'maxPatches': maxPatches,
    'maxVertices': maxVertices,
    'sceneInputScale': sceneInputScale,
    'ssrSteps': ssrSteps,
    'shaftSteps': shaftSteps,
    'sprayParticleCap': sprayParticleCap,
    'gpuBudgetBytes': gpuBudgetBytes,
    'causticResolution': causticResolution,
    'segments': segments,
    'maxScreenError': maxScreenError,
  };
  factory OceanQualitySettings.fromJson(Map<String, Object?> data) {
    const keys = {
      'version',
      'fftResolution',
      'maxBands',
      'maxPatches',
      'maxVertices',
      'sceneInputScale',
      'ssrSteps',
      'shaftSteps',
      'sprayParticleCap',
      'gpuBudgetBytes',
      'causticResolution',
      'segments',
      'maxScreenError',
    };
    if (data.length != keys.length ||
        !data.keys.every(keys.contains) ||
        data['version'] != 1) {
      throw const FormatException('Unknown ocean quality version or fields.');
    }
    int integer(String key) {
      final v = data[key];
      if (v is! int) throw FormatException('Expected integer $key.');
      return v;
    }

    double number(String key) {
      final v = data[key];
      if (v is! num) throw FormatException('Expected number $key.');
      return v.toDouble();
    }

    try {
      return OceanQualitySettings(
        fftResolution: integer('fftResolution'),
        maxBands: integer('maxBands'),
        maxPatches: integer('maxPatches'),
        maxVertices: integer('maxVertices'),
        sceneInputScale: number('sceneInputScale'),
        ssrSteps: integer('ssrSteps'),
        shaftSteps: integer('shaftSteps'),
        sprayParticleCap: integer('sprayParticleCap'),
        gpuBudgetBytes: integer('gpuBudgetBytes'),
        causticResolution: integer('causticResolution'),
        segments: integer('segments'),
        maxScreenError: number('maxScreenError'),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid ocean quality: $error');
    }
  }
}
