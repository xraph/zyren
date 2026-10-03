import 'time.dart';

enum GeoSampleAvailability {
  available,
  stale,
  outsideCoverage,
  unavailable,
  failed,
}

final class GeoSample<T extends Object> {
  final GeoSampleAvailability availability;
  final T? value;
  final String? frameId, sourceRevision, units;
  final int? frameRevision;
  final GeoInstant? time;
  final Duration? age;
  final double? error;
  final Object? failure;
  GeoSample({
    required this.availability,
    this.value,
    this.frameId,
    this.frameRevision,
    this.sourceRevision,
    this.units,
    this.time,
    this.age,
    this.error,
    this.failure,
  }) {
    if ((availability == GeoSampleAvailability.available ||
            availability == GeoSampleAvailability.stale) &&
        (value == null ||
            frameId == null ||
            frameId!.trim().isEmpty ||
            frameRevision == null ||
            frameRevision! < 0 ||
            sourceRevision == null ||
            sourceRevision!.trim().isEmpty ||
            units == null ||
            units!.trim().isEmpty ||
            time == null)) {
      throw ArgumentError(
        'Available samples need a value, units, frame, time and source provenance.',
      );
    }
    if ((age?.isNegative ?? false) ||
        (error != null && (!error!.isFinite || error! < 0)) ||
        (availability == GeoSampleAvailability.failed && failure == null)) {
      throw ArgumentError(
        'Sample age/error must be nonnegative and failures need a cause.',
      );
    }
  }
  bool isCurrent({
    required String frameId,
    required int frameRevision,
    required String sourceRevision,
    required GeoInstant time,
    Duration? maximumAge,
  }) =>
      availability == GeoSampleAvailability.available &&
      this.frameId == frameId &&
      this.frameRevision == frameRevision &&
      this.sourceRevision == sourceRevision &&
      this.time == time &&
      (maximumAge == null || (age != null && age! <= maximumAge));
}
