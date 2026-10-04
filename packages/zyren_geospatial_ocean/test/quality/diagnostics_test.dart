import 'package:test/test.dart';
import 'package:zyren/rendering.dart' show GpuInspection;
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';
import 'admission_test.dart' show device;

void main() {
  test(
    'unavailable metrics stay null and device allocations are not water residency',
    () {
      final state = fixtureSea(resolution: 64),
          quality = OceanRenderQuality.low.settings;
      final admission = OceanQualityAdmission.evaluate(
        settings: quality,
        state: state,
        chartIds: [0],
        capabilities: device(),
      );
      OceanDiagnostics snapshot([GpuInspection? inspection]) =>
          OceanDiagnostics(
            status: 'ready',
            seaStateRevision: state.revision,
            quality: quality,
            admission: admission,
            ownedPayloadBytes: admission.candidateBytes,
            publicationRevision: 1,
            seconds: 0,
            transitionFraction: 1,
            activeEffects: {'waves'},
            passes: [
              OceanPassMeasurement(
                name: 'waves',
                status: OceanPassStatus.unavailable,
              ),
            ],
            device: inspection,
          );
      final unknown = snapshot().toJson();
      expect((unknown['device'] as Map)['nativeAllocatedBytes'], isNull);
      expect((unknown['device'] as Map)['physicalResidentBytes'], isNull);
      expect((unknown['physicalQuery'] as Map)['heightErrorMetres'], isNull);
      expect((unknown['physicalQuery'] as Map)['status'], 'unavailable');
      expect((unknown['passes'] as List).single['gpuMilliseconds'], isNull);
      final measured = snapshot(
        GpuInspection(
          deviceAllocatedBytes: 1000000,
          deviceAllocationSource: 'native fixture',
          registryPayloadBytes: 2000,
          totalAllocations: 5,
          allocations: [],
        ),
      ).toJson();
      expect((measured['device'] as Map)['nativeAllocatedBytes'], 1000000);
      expect((measured['device'] as Map)['scope'], 'whole-device');
      expect((measured['device'] as Map)['physicalResidentBytes'], isNull);
      expect(
        () => OceanPassMeasurement(
          name: 'waves',
          status: OceanPassStatus.executed,
          gpuTime: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => OceanPassMeasurement(
          name: 'waves',
          status: OceanPassStatus.unavailable,
          dispatches: 0,
        ),
        throwsArgumentError,
      );
    },
  );
}
