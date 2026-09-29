import 'asset_request.dart';
import 'asset_scope.dart';
import 'hdr_image.dart';
import 'source_resolver.dart';

/// Loads immutable HDR pixels using the decoder configured in [AssetServices].
/// Reuses the scope's source policy, cancellation and aggregate byte budgets.
final class HdrImageLoader extends AssetLoader<HdrImageData> {
  const HdrImageLoader();
  @override
  Object get cacheKey => HdrImageLoader;
  @override
  Future<DecodedAsset<HdrImageData>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final image = await context.decodeHdrImage(source.bytes);
    return DecodedAsset(create: () => image, release: (_) {});
  }
}
