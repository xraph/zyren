enum RenderFeature {
  indexedMeshes,
  diffuseLighting,
  unlitMaterials,
  rgbaReadback,
  sharedTexture,
  nativeView,
  compute,
  storageTextures,
  indirectDraws,
  timestampQueries,
}

/// Limits enforced by the backend, even if the adapter can allocate more.
class DeviceLimits {
  final int maxTextureDimension2D;
  final int maxGeometryBytes;
  final Set<int> sampleCounts;
  DeviceLimits({
    required this.maxTextureDimension2D,
    required this.maxGeometryBytes,
    Set<int> sampleCounts = const {1},
  }) : sampleCounts = Set.unmodifiable(sampleCounts) {
    if (maxTextureDimension2D < 1 ||
        maxGeometryBytes < 1 ||
        sampleCounts.isEmpty ||
        sampleCounts.any((value) => value < 1)) {
      throw ArgumentError('Device limits must be positive.');
    }
  }
}

class DeviceCapabilities {
  final String name;
  final String? backend, adapterName, driverDescription;
  final Set<RenderFeature> features;
  final DeviceLimits limits;
  DeviceCapabilities({
    required this.name,
    this.backend,
    this.adapterName,
    this.driverDescription,
    required Set<RenderFeature> features,
    required this.limits,
  }) : features = Set.unmodifiable(features);
  bool supports(RenderFeature feature) => features.contains(feature);
}
