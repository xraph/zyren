import 'package:zyren/rendering.dart' show GpuInspection, NativeFrameProfile;
import '../queries/query.dart';
import 'admission.dart';
import 'settings.dart';

enum OceanPassStatus { unavailable, executed, failed }

/// Host elapsed time includes submission/completion waits. It is never a GPU
/// timestamp. A plugin can provide GPU time only with its measurement source.
final class OceanPassMeasurement {
  final String name, gpuTimeSource;
  final OceanPassStatus status;
  final Duration? hostElapsed, gpuTime;
  final int? dispatches, drawCalls;
  OceanPassMeasurement({
    required this.name,
    required this.status,
    this.hostElapsed,
    this.gpuTime,
    this.gpuTimeSource = 'unavailable',
    this.dispatches,
    this.drawCalls,
  }) {
    if (name.trim().isEmpty ||
        name.length > 128 ||
        gpuTimeSource.length > 128 ||
        (hostElapsed?.isNegative ?? false) ||
        (gpuTime?.isNegative ?? false) ||
        (dispatches != null && dispatches! < 0) ||
        (drawCalls != null && drawCalls! < 0) ||
        (gpuTime != null &&
            (gpuTimeSource.isEmpty || gpuTimeSource == 'unavailable')) ||
        (status == OceanPassStatus.unavailable &&
            (hostElapsed != null ||
                gpuTime != null ||
                dispatches != null ||
                drawCalls != null))) {
      throw ArgumentError('Invalid ocean pass measurement.');
    }
  }
  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.name,
    'hostElapsedMilliseconds': hostElapsed == null
        ? null
        : hostElapsed!.inMicroseconds / 1000,
    'gpuMilliseconds': gpuTime == null ? null : gpuTime!.inMicroseconds / 1000,
    'gpuTimeSource': gpuTimeSource,
    'dispatches': dispatches,
    'drawCalls': drawCalls,
  };
}

/// One read-only report. Device/frame counters retain their scope and are not
/// attributed to water. Unknown measurements remain null, including residency.
final class OceanDiagnostics {
  final String status, seaStateRevision;
  final OceanQualitySettings quality;
  final OceanQualityAdmission admission;
  final int ownedPayloadBytes, publicationRevision;
  final double seconds, transitionFraction;
  final Set<String> activeEffects;
  final List<OceanPassMeasurement> passes;
  final int? patchCount, vertexCount, viewCount;
  final OceanSample? lastQuery;
  final GpuInspection? device;
  final NativeFrameProfile? presentationFrame;
  final Object? lastFailure;
  final List<Object> retirementFailures;
  OceanDiagnostics({
    required this.status,
    required this.seaStateRevision,
    required this.quality,
    required this.admission,
    required this.ownedPayloadBytes,
    required this.publicationRevision,
    required this.seconds,
    required this.transitionFraction,
    required Set<String> activeEffects,
    required Iterable<OceanPassMeasurement> passes,
    this.patchCount,
    this.vertexCount,
    this.viewCount,
    this.lastQuery,
    this.device,
    this.presentationFrame,
    this.lastFailure,
    Iterable<Object> retirementFailures = const [],
  }) : activeEffects = Set.unmodifiable(activeEffects),
       passes = List.unmodifiable(passes.take(129)),
       retirementFailures = List.unmodifiable(retirementFailures) {
    if (!{'ready', 'busy', 'faulted', 'closed'}.contains(status) ||
        (lastQuery != null &&
            lastQuery!.seaStateRevision != seaStateRevision) ||
        this.passes.length > 128 ||
        this.passes.map((p) => p.name).toSet().length != this.passes.length ||
        [
          ownedPayloadBytes,
          publicationRevision,
          patchCount,
          vertexCount,
          viewCount,
        ].any((v) => v != null && v < 0) ||
        !seconds.isFinite ||
        !transitionFraction.isFinite ||
        transitionFraction < 0 ||
        transitionFraction > 1) {
      throw ArgumentError('Invalid ocean diagnostic snapshot.');
    }
  }
  Map<String, Object?> toJson() => {
    'version': 1,
    'status': status,
    'seaStateRevision': seaStateRevision,
    'quality': quality.toJson(),
    'preset': quality.preset?.name,
    'publicationRevision': publicationRevision,
    'seconds': seconds,
    'transitionFraction': transitionFraction,
    'activeEffects': activeEffects.toList()..sort(),
    'chartCount': admission.chartCount,
    'renderBands': admission.renderBands,
    'patchCount': patchCount,
    'vertexCount': vertexCount,
    'viewCount': viewCount,
    'payload': {
      'ownedBytes': ownedPayloadBytes,
      'admittedPeakBytes': admission.peakBytes,
      'candidateBudgetBytes': admission.candidateBudgetBytes,
      'peakBudgetBytes': admission.peakBudgetBytes,
      'candidateHostCoefficientBytes': admission.hostCoefficientBytes,
      'breakdown': admission.breakdown,
    },
    'passes': [for (final pass in passes) pass.toJson()],
    'physicalQuery': {
      'status': lastQuery == null
          ? 'unavailable'
          : lastQuery!.available
          ? 'available'
          : 'failed',
      'failure': lastQuery?.failure?.name,
      'ageAtDeliveryMilliseconds': lastQuery?.age == null
          ? null
          : lastQuery!.age!.inMicroseconds / 1000,
      'heightErrorMetres': lastQuery?.accuracy?.heightErrorMetres,
      'seaStateRevision': lastQuery?.seaStateRevision,
      'frameRevision': lastQuery?.frameRevision,
      'coverageRevision': lastQuery?.coverageRevision,
    },
    'device': {
      'scope': 'whole-device',
      'registryPayloadBytes': device?.registryPayloadBytes,
      'nativeAllocatedBytes': device?.deviceAllocatedBytes,
      'allocationSource': device?.deviceAllocationSource ?? 'unavailable',
      'physicalResidentBytes': device?.residentBytes,
      'allocationCount': device?.totalAllocations,
    },
    'presentationFrame': presentationFrame == null
        ? null
        : {'scope': 'whole-scene-frame', ...presentationFrame!.toJson()},
    'lastFailure': lastFailure?.toString(),
    'retirementFailures': [
      for (final failure in retirementFailures) failure.toString(),
    ],
  };
}
