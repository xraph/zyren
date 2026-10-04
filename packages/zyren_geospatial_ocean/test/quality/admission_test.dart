import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

DeviceCapabilities device({
  int dimension = 8192,
  int? bytes,
  Set<RenderFeature>? features,
}) => DeviceCapabilities(
  name: 'bounded fixture',
  features: features ?? RenderFeature.values.toSet(),
  limits: DeviceLimits(
    maxTextureDimension2D: dimension,
    maxGeometryBytes: 64 * 1024 * 1024,
    maxResidentResourceBytes: bytes,
    sampleCounts: {1, 4},
  ),
);
void main() {
  test(
    'admission counts every chart, view, history and retained transition allocation',
    () {
      final state = fixtureSea(resolution: 128),
          low = OceanRenderQuality.low.settings;
      final views = [
        OceanViewAllocation(
          id: 'main',
          size: PhysicalSize(640, 480),
          sampleCount: 4,
          geometryBytes: 1024,
          materialBytes: 256,
          historyBytes: 8192,
          boundaryCapture: true,
          mediumTransport: true,
        ),
        OceanViewAllocation(
          id: 'rear',
          size: PhysicalSize(320, 240),
          geometryBytes: 512,
          materialBytes: 128,
        ),
      ];
      final first = OceanQualityAdmission.evaluate(
        settings: low,
        state: state,
        chartIds: [0, 4],
        capabilities: device(),
        views: views,
      );
      final expectedViews =
          320 * 240 * 60 +
          640 * 480 * 12 +
          640 * 480 * 16 +
          1024 +
          256 +
          8192 +
          160 * 120 * 12 +
          512 +
          128;
      expect(
        first.candidateBytes,
        OceanWaveStream.estimateBytes(64, 1, 2) + expectedViews,
      );
      final next = OceanQualityAdmission.evaluate(
        settings: OceanRenderQuality.medium.settings,
        state: state,
        chartIds: [0, 4],
        capabilities: device(),
        views: views,
        retainedBytes: first.candidateBytes,
        transitionFrom: low,
      );
      expect(
        next.transitionBytes,
        OceanWaveBlend.estimate(64, 1, 128, 1, 2).bytes,
      );
      expect(
        next.peakBytes,
        next.candidateBytes + first.candidateBytes + next.transitionBytes,
      );
      expect(next.renderBands, 1);
      expect(next.hostCoefficientBytes, 128 * 128 * 24 * 2);
      expect(
        () => OceanQualityAdmission.evaluate(
          settings: low.copyWith(gpuBudgetBytes: first.peakBytes - 1),
          state: state,
          chartIds: [0, 4],
          capabilities: device(),
          views: views,
        ),
        throwsA(isA<ResourceException>()),
      );
    },
  );
  test(
    'unsupported source, capability, dimensions and native allowances reject before preparation',
    () {
      final state = fixtureSea(resolution: 128),
          low = OceanRenderQuality.low.settings;
      void admit(
        DeviceCapabilities backend, {
        OceanQualitySettings? settings,
        List<OceanViewAllocation> views = const [],
      }) => OceanQualityAdmission.evaluate(
        settings: settings ?? low,
        state: state,
        chartIds: [0],
        capabilities: backend,
        views: views,
      );
      expect(
        () => admit(device(), settings: OceanRenderQuality.ultra.settings),
        throwsA(isA<OceanQualityException>()),
      );
      expect(
        () => admit(device(features: {RenderFeature.compute})),
        throwsA(isA<OceanQualityException>()),
      );
      expect(
        () => admit(device(dimension: 128)),
        throwsA(isA<ResourceException>()),
      );
      expect(
        () => admit(device(bytes: 1000)),
        throwsA(isA<ResourceException>()),
      );
      expect(
        () => admit(
          device(dimension: 256),
          views: [
            OceanViewAllocation(id: 'main', size: PhysicalSize(1024, 512)),
          ],
        ),
        throwsA(isA<ResourceException>()),
      );
      expect(
        () => admit(
          device(),
          views: [
            OceanViewAllocation(id: 'same', size: PhysicalSize(1, 1)),
            OceanViewAllocation(id: 'same', size: PhysicalSize(1, 1)),
          ],
        ),
        throwsArgumentError,
      );
    },
  );
}
