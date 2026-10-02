import 'package:crypto/crypto.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

/// Records only explicitly selected public assets without retaining their bytes.
final class AssetFingerprints implements ByteSourceResolver {
  final ByteSourceResolver delegate;
  final Set<Uri> sources;
  final _records = <String, Map<String, Object>>{};

  AssetFingerprints(this.delegate, Set<Uri> sources)
    : sources = Set.unmodifiable(sources);

  List<Map<String, Object>> get records => [
    for (final key in _records.keys.toList()..sort())
      Map.unmodifiable(_records[key]!),
  ];

  AssetServices wrap(AssetServices services) => AssetServices(
    resolver: this,
    imageDecoder: services.imageDecoder,
    textureDecoder: services.textureDecoder,
    bufferDecoder: services.bufferDecoder,
    meshDecoder: services.meshDecoder,
    limits: services.limits,
    policy: services.policy,
    onCleanupError: services.onCleanupError,
  );

  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    final result = await delegate.read(uri, context);
    if (sources.contains(uri)) {
      _records[uri.toString()] = {
        'uri': uri.toString(),
        'bytes': result.bytes.length,
        'sha256': sha256.convert(result.bytes).toString(),
      };
    }
    return result;
  }
}
