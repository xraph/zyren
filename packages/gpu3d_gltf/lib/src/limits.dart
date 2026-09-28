/// Parser metadata and accessor limits, in addition to the core asset budgets.
/// [maxPrimitives] bounds decoded primitives and expanded meshes per scene.
final class GltfLimits {
  final int maxJsonBytes,
      maxJsonDepth,
      maxJsonTokens,
      maxObjects,
      maxAccessorElements,
      maxNodes,
      maxNodeDepth,
      maxPrimitives;
  const GltfLimits({
    this.maxJsonBytes = 8 * 1024 * 1024,
    this.maxJsonDepth = 64,
    this.maxJsonTokens = 500000,
    this.maxObjects = 100000,
    this.maxAccessorElements = 3000000,
    this.maxNodes = 4096,
    this.maxNodeDepth = 128,
    this.maxPrimitives = 4096,
  });
  void validate() {
    for (final (name, value, ceiling) in [
      ('maxJsonBytes', maxJsonBytes, 32 * 1024 * 1024),
      ('maxJsonDepth', maxJsonDepth, 256),
      ('maxJsonTokens', maxJsonTokens, 2000000),
      ('maxObjects', maxObjects, 1000000),
      ('maxAccessorElements', maxAccessorElements, 3000000),
      ('maxNodes', maxNodes, 32768),
      ('maxNodeDepth', maxNodeDepth, 256),
      ('maxPrimitives', maxPrimitives, 4096),
    ]) {
      RangeError.checkValueInInterval(value, 1, ceiling, name);
    }
  }

  Object get _key => (
    maxJsonBytes,
    maxJsonDepth,
    maxJsonTokens,
    maxObjects,
    maxAccessorElements,
    maxNodes,
    maxNodeDepth,
    maxPrimitives,
  );
  @override
  bool operator ==(Object other) => other is GltfLimits && _key == other._key;
  @override
  int get hashCode => _key.hashCode;
}
