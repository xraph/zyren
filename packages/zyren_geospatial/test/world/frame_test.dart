import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'height datums require a provider and never substitute ellipsoid height',
    () async {
      final geo = GeospatialPlugin();
      final position = Geodetic.degrees(2, 1, 25);
      final identity = await geo.heightProvider.convert(
        position,
        from: GeoHeightDatum.ellipsoid,
        to: GeoHeightDatum.ellipsoid,
        time: geo.clock.instant,
      );
      expect(identity.value, 25);
      expect(identity.availability, GeoSampleAvailability.available);
      final missing = await geo.heightProvider.convert(
        position,
        from: GeoHeightDatum.ellipsoid,
        to: GeoHeightDatum.meanSeaLevel,
        time: geo.clock.instant,
      );
      expect(missing.availability, GeoSampleAvailability.unavailable);
      expect(missing.value, isNull);
    },
  );

  test('local positions and vectors round trip at poles and dateline', () {
    for (final origin in [
      Geodetic.degrees(0, 0),
      Geodetic.degrees(179.99, 70),
      Geodetic.degrees(-179.99, -70),
      Geodetic.degrees(45, 90),
      Geodetic.degrees(45, -90),
    ]) {
      final frame = GeoWorldFrame(
        reference: const GeospatialReference(),
        origin: origin,
      );
      const local = Vec3(120, -30, 5);
      expect(
        frame.toLocal(frame.toEcef(local)).distanceTo(local),
        lessThan(1e-8),
      );
      const velocity = Vec3(30, -15, 2);
      expect(
        frame.vectorToLocal(frame.vectorToEcef(velocity)).distanceTo(velocity),
        lessThan(1e-10),
      );
    }
  });

  test(
    'rebase notifies the old revision and rotates forces without translation',
    () async {
      final frame = GeoWorldFrame(
        reference: const GeospatialReference(),
        origin: Geodetic.degrees(0, 0),
      );
      final oldPoint = frame.toEcef(const Vec3(100, 10, 5));
      final oldVelocity = frame.vectorToEcef(const Vec3(1, 0, 0));
      var observed = -1;
      final subscription = frame.rebases.listen((event) {
        observed = frame.revision;
      });
      final event = frame.rebase(Geodetic.degrees(2, 1));
      expect(observed, 0);
      expect(frame.revision, 1);
      expect(
        event
            .transformPosition(const Vec3(100, 10, 5))
            .distanceTo(frame.toLocal(oldPoint)),
        lessThan(1e-8),
      );
      expect(
        event
            .transformVector(const Vec3(1, 0, 0))
            .distanceTo(frame.vectorToLocal(oldVelocity)),
        lessThan(1e-12),
      );
      expect(
        event.transformVector(const Vec3(1, 0, 0)).length,
        closeTo(1, 1e-12),
      );
      await subscription.cancel();
      await frame.dispose();
    },
  );

  test(
    'samples require provenance and reject a changed frame, source or tick',
    () {
      final time = GeoInstant(tick: 1, hz: 60, epoch: DateTime.utc(2026));
      expect(
        () => GeoSample<double>(
          availability: GeoSampleAvailability.available,
          frameId: 'ecef',
          frameRevision: 0,
          sourceRevision: 'v1',
          time: time,
          units: 'm',
        ),
        throwsArgumentError,
      );
      final sample = GeoSample<double>(
        availability: GeoSampleAvailability.available,
        value: 12,
        frameId: 'ecef',
        frameRevision: 0,
        sourceRevision: 'v1',
        time: time,
        units: 'm',
        error: .01,
      );
      expect(
        sample.isCurrent(
          frameId: 'ecef',
          frameRevision: 0,
          sourceRevision: 'v1',
          time: time,
        ),
        isTrue,
      );
      expect(
        sample.isCurrent(
          frameId: 'ecef',
          frameRevision: 1,
          sourceRevision: 'v1',
          time: time,
        ),
        isFalse,
      );
      expect(
        sample.isCurrent(
          frameId: 'ecef',
          frameRevision: 0,
          sourceRevision: 'v2',
          time: time,
        ),
        isFalse,
      );
      expect(
        sample.isCurrent(
          frameId: 'ecef',
          frameRevision: 0,
          sourceRevision: 'v1',
          time: GeoInstant(tick: 2, hz: 60, epoch: time.epoch),
        ),
        isFalse,
      );
    },
  );
}
