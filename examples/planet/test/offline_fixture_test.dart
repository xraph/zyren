import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/layers/offline_fixture.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'download, cancel, resume and cold field reads use persisted bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp('offline-lab-');
      var repository = await OfflineRepository.open(
        directory,
        latency: const Duration(milliseconds: 30),
      );
      try {
        final downloading = repository.download();
        await repository.job.changes.firstWhere(
          (p) => p.verifiedResources == 1,
        );
        await repository.job.cancel();
        expect((await downloading).complete, isFalse);
        expect(repository.job.progress.state, GeoRegionJobState.paused);
        expect((await repository.download()).complete, isTrue);
        repository.denySource = true;
        expect((await repository.download()).complete, isFalse);
        expect(
          (await repository.diagnostics.snapshot()).failures,
          hasLength(3),
        );
        repository.denySource = false;
        expect((await repository.download()).complete, isTrue);
        await repository.close();
        repository = await OfflineRepository.open(directory);
        expect(repository.job.progress.state, GeoRegionJobState.complete);
        final view = repository.createView(offline: true);
        final time = GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026));
        final depth = await view.bathymetry.sample(Geodetic(-.0002, 0), time);
        expect(depth.value, closeTo(105, 1e-8));
        expect((await view.coast.sample(Geodetic(-.0002, 0), time)).value, 1);
        expect((await view.coast.sample(Geodetic(.0002, 0), time)).value, 0);
        expect(
          (await view.coast.sample(Geodetic(.5, 0), time)).availability,
          GeoSampleAvailability.outsideCoverage,
        );
        expect((await repository.diagnostics.snapshot()).transportAttempts, 0);
        view.dispose();
      } finally {
        await repository.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
