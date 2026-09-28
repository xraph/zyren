/// Parser metadata and accessor limits, in addition to the core asset budgets.
final class GltfLimits {
  final int maxJsonBytes,
      maxJsonDepth,
      maxJsonTokens,
      maxObjects,
      maxAccessorElements;
  const GltfLimits({
    this.maxJsonBytes = 8 * 1024 * 1024,
    this.maxJsonDepth = 64,
    this.maxJsonTokens = 500000,
    this.maxObjects = 100000,
    this.maxAccessorElements = 3000000,
  });
  void validate() {
    for (final (name, value, ceiling) in [
      ('maxJsonBytes', maxJsonBytes, 32 * 1024 * 1024),
      ('maxJsonDepth', maxJsonDepth, 256),
      ('maxJsonTokens', maxJsonTokens, 2000000),
      ('maxObjects', maxObjects, 1000000),
      ('maxAccessorElements', maxAccessorElements, 3000000),
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
  );
  @override
  bool operator ==(Object other) => other is GltfLimits && _key == other._key;
  @override
  int get hashCode => _key.hashCode;
}
