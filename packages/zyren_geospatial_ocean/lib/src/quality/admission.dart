import 'package:zyren/zyren.dart';
import '../waves/sea_state.dart';
import '../rendering/wave_render_data.dart';
import '../rendering/wave_blend.dart';
import 'settings.dart';

enum OceanQualityErrorCode {
  canonicalResolution,
  unsupportedFeature,
  unsupportedFormat,
}

final class OceanQualityException implements Exception {
  final OceanQualityErrorCode code;
  final String message;
  final Set<RenderFeature> missingFeatures;
  OceanQualityException(
    this.code,
    this.message, {
    Set<RenderFeature> missingFeatures = const {},
  }) : missingFeatures = Set.unmodifiable(missingFeatures);
  @override
  String toString() => 'OceanQualityException(${code.name}): $message';
}

/// Planned payload for one real view. Geometry/material/history bytes must come
/// from the candidate's owned recipes. Targets are counted here from dimensions;
/// do not include them again in those payloads. Renderer bookkeeping, pipeline
/// objects and driver residency are outside logical payload admission.
final class OceanViewAllocation {
  final String id;
  final PhysicalSize size;
  final int sampleCount, geometryBytes, materialBytes, historyBytes;
  final bool boundaryCapture, mediumTransport;
  OceanViewAllocation({
    required this.id,
    required this.size,
    this.sampleCount = 1,
    this.geometryBytes = 0,
    this.materialBytes = 0,
    this.historyBytes = 0,
    this.boundaryCapture = false,
    this.mediumTransport = false,
  }) {
    if (id.trim().isEmpty ||
        id.length > 128 ||
        size.width < 1 ||
        size.height < 1 ||
        size.width > 65536 ||
        size.height > 65536 ||
        !{1, 4}.contains(sampleCount) ||
        [
          geometryBytes,
          materialBytes,
          historyBytes,
        ].any((b) => b < 0 || b > 1 << 30) ||
        (mediumTransport && !boundaryCapture)) {
      throw ArgumentError('Invalid ocean view allocation plan.');
    }
  }
}

/// Preflight accounting without GPU side effects. Native allocation still makes
/// the final decision; another owner can consume device resources after this
/// calculation. Candidate construction must roll back on any later failure.
final class OceanQualityAdmission {
  final int renderBands,
      chartCount,
      candidateBytes,
      transitionBytes,
      retainedBytes,
      hostCoefficientBytes;
  final Map<String, int> breakdown;
  final Set<RenderFeature> requiredFeatures;
  int get peakBytes => candidateBytes + transitionBytes + retainedBytes;
  OceanQualityAdmission._(
    this.renderBands,
    this.chartCount,
    this.candidateBytes,
    this.transitionBytes,
    this.retainedBytes,
    this.hostCoefficientBytes,
    Map<String, int> breakdown,
    Set<RenderFeature> features,
  ) : breakdown = Map.unmodifiable(breakdown),
      requiredFeatures = Set.unmodifiable(features);

  static OceanQualityAdmission evaluate({
    required OceanQualitySettings settings,
    required OceanSeaState state,
    required Iterable<int> chartIds,
    required DeviceCapabilities capabilities,
    Iterable<OceanViewAllocation> views = const [],
    int retainedBytes = 0,
    OceanQualitySettings? transitionFrom,
    Map<String, int> additionalPayloads = const {},
    Set<RenderFeature> additionalFeatures = const {},
  }) {
    final charts = chartIds.take(7).toList(), viewList = views.take(9).toList();
    if (charts.isEmpty ||
        charts.length > 6 ||
        charts.toSet().length != charts.length ||
        charts.any((id) => id < 0 || id > 5) ||
        viewList.length > 8 ||
        viewList.map((v) => v.id).toSet().length != viewList.length ||
        retainedBytes < 0 ||
        retainedBytes > 1 << 40 ||
        additionalPayloads.length > 128 ||
        additionalPayloads.entries.any(
          (e) =>
              e.key.trim().isEmpty ||
              e.key.length > 128 ||
              e.value < 0 ||
              e.value > 1 << 30,
        )) {
      throw ArgumentError('Invalid ocean resource admission inputs.');
    }
    if (settings.fftResolution > state.canonicalResolution ||
        (transitionFrom != null &&
            transitionFrom.fftResolution > state.canonicalResolution)) {
      throw OceanQualityException(
        OceanQualityErrorCode.canonicalResolution,
        'Requested visual resolution exceeds the canonical sea state.',
      );
    }
    final required = {
      RenderFeature.compute,
      RenderFeature.storageTextures,
      RenderFeature.floatTextures,
      RenderFeature.renderGraphs,
      RenderFeature.meshShaders,
      RenderFeature.meshSceneInputs,
      if (settings.sceneInputScale != 1) RenderFeature.scaledOpaqueCapture,
      if (viewList.any((v) => v.boundaryCapture)) RenderFeature.sceneCapture,
      if (viewList.any((v) => v.mediumTransport)) RenderFeature.postprocessing,
      ...additionalFeatures,
    };
    final missing = required.where((f) => !capabilities.supports(f)).toSet();
    if (missing.isNotEmpty) {
      throw OceanQualityException(
        OceanQualityErrorCode.unsupportedFeature,
        'Backend cannot execute the requested ocean profile.',
        missingFeatures: missing,
      );
    }
    if (capabilities.textureFormats.isNotEmpty &&
        (!capabilities.textureFormats.contains(TextureFormat.rgba32Float) ||
            (viewList.isNotEmpty &&
                !capabilities.textureFormats.contains(
                  TextureFormat.rgba16Float,
                )))) {
      throw OceanQualityException(
        OceanQualityErrorCode.unsupportedFormat,
        'Backend does not advertise the required floating-point texture formats.',
      );
    }
    final limits = capabilities.limits;
    void texture(
      String name,
      int width,
      int height,
      int bytesPerPixel, {
      int samples = 1,
    }) {
      if (width > limits.maxTextureDimension2D ||
          height > limits.maxTextureDimension2D ||
          !limits.sampleCounts.contains(samples) ||
          width * height * bytesPerPixel * samples > 64 * 1024 * 1024) {
        throw ResourceException(
          ResourceErrorCode.budgetExceeded,
          '$name exceeds texture dimensions, samples or payload limits.',
        );
      }
    }

    final bands = state.bands.length < settings.maxBands
        ? state.bands.length
        : settings.maxBands;
    texture(
      'Wave atlas',
      settings.fftResolution * 4,
      settings.fftResolution * bands,
      16,
    );
    final waveBytes = OceanWaveStream.estimateBytes(
      settings.fftResolution,
      bands,
      charts.length,
    );
    final breakdown = <String, int>{'waves': waveBytes};
    for (final view in viewList) {
      final width = view.size.width, height = view.size.height;
      if (width > limits.maxTextureDimension2D ||
          height > limits.maxTextureDimension2D ||
          !limits.sampleCounts.contains(view.sampleCount) ||
          view.geometryBytes > limits.maxGeometryBytes) {
        throw ResourceException(
          ResourceErrorCode.budgetExceeded,
          'View ${view.id} exceeds backend dimensions, samples or geometry allowance.',
        );
      }
      final w = (width * settings.sceneInputScale).ceil(),
          h = (height * settings.sceneInputScale).ceil();
      texture('Opaque color ${view.id}', w, h, 8, samples: view.sampleCount);
      texture('Opaque depth ${view.id}', w, h, 4, samples: view.sampleCount);
      final opaqueBytes = w * h * 12 * (view.sampleCount == 4 ? 5 : 1);
      if (opaqueBytes > 128 * 1024 * 1024) {
        throw ResourceException(
          ResourceErrorCode.budgetExceeded,
          'View ${view.id} exceeds the native opaque capture allowance.',
        );
      }
      breakdown['view:${view.id}:opaque'] = opaqueBytes;
      if (view.boundaryCapture) {
        texture('Boundary ${view.id}', width, height, 8);
        texture('Boundary depth ${view.id}', width, height, 4);
        breakdown['view:${view.id}:boundary'] = width * height * 12;
      }
      if (view.mediumTransport) {
        texture('Medium ${view.id}', width, height, 8);
        breakdown['view:${view.id}:medium'] = width * height * 16;
      }
      breakdown['view:${view.id}:geometry'] = view.geometryBytes;
      breakdown['view:${view.id}:materials'] = view.materialBytes;
      breakdown['view:${view.id}:history'] = view.historyBytes;
    }
    for (final entry in additionalPayloads.entries) {
      breakdown['extension:${entry.key}'] = entry.value;
    }
    final candidate = breakdown.values.fold(0, (a, b) => a + b);
    var transition = 0;
    if (transitionFrom != null) {
      final oldBands = state.bands.length < transitionFrom.maxBands
          ? state.bands.length
          : transitionFrom.maxBands;
      final blend = OceanWaveBlend.estimate(
        transitionFrom.fftResolution,
        oldBands,
        settings.fftResolution,
        bands,
        charts.length,
      );
      texture('Wave transition atlas', blend.width, blend.height, 16);
      transition = blend.bytes;
      breakdown['transition'] = transition;
    }
    breakdown['retained'] = retainedBytes;
    final peak = candidate + transition + retainedBytes;
    if (peak > settings.gpuBudgetBytes ||
        (limits.maxResidentResourceBytes != null &&
            peak > limits.maxResidentResourceBytes!)) {
      throw ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Ocean peak payload $peak exceeds profile ${settings.gpuBudgetBytes} or the backend allowance.',
      );
    }
    return OceanQualityAdmission._(
      bands,
      charts.length,
      candidate,
      transition,
      retainedBytes,
      state.canonicalResolution *
          state.canonicalResolution *
          state.bands.length *
          24 *
          charts.length,
      breakdown,
      required,
    );
  }
}
