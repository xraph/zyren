part of '../zyren_3d_tiles.dart';

/// A streamed resource is either renderable content or another hierarchy.
final class _StreamContent {
  final TileModel3D? model;
  final Tileset3D? hierarchy;
  final int decodedBytes;
  int get residentBytes => model?.residentBytes ?? 0;
  _StreamContent.model(TileModel3D value)
    : model = value,
      hierarchy = null,
      decodedBytes = value.decodedBytes;
  _StreamContent.hierarchy(Tileset3D value, this.decodedBytes)
    : hierarchy = value,
      model = null;
}

final class _StreamContentLoader extends AssetLoader<_StreamContent> {
  final TileNode3D node;
  final Tiles3DLimits limits;
  final GltfOptions options;
  final void Function(Future<void>) track;
  const _StreamContentLoader(this.node, this.limits, this.options, this.track);
  @override
  Future<DecodedAsset<_StreamContent>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final done = Completer<void>();
    track(done.future);
    try {
      if (node._implicit != null) {
        final hierarchy = await _decodeSubtree(
          node._implicit!,
          source,
          context,
        );
        return DecodedAsset(
          create: () =>
              _StreamContent.hierarchy(hierarchy, context.decodedBytes),
          release: (_) {},
        );
      }
      final magic = source.bytes.length < 4
          ? 0
          : ByteData.sublistView(source.bytes).getUint32(0, Endian.little);
      if (magic != 0x46546c67 && magic != 0x6d643362) {
        final json = _json(
          source.bytes,
          math.max(limits.maxManifestBytes, options.limits.maxJsonBytes),
          math.max(limits.maxDepth * 2 + 16, options.limits.maxJsonDepth),
        );
        if (json.containsKey('root')) {
          if (node.children.isNotEmpty || node._implicitContent) _invalid();
          final decoded = await _TilesetLoader(
            limits,
            referringNode: node,
          ).decode(source, context);
          final bytes = context.decodedBytes;
          return DecodedAsset(
            create: () => _StreamContent.hierarchy(decoded.create(), bytes),
            release: (value) => decoded.release(value.hierarchy!),
            dispose: decoded.dispose,
          );
        }
      }
      final decoded = await _ContentLoader(options).decode(source, context);
      return DecodedAsset(
        create: () => _StreamContent.model(decoded.create()),
        release: (value) => decoded.release(value.model!),
        dispose: decoded.dispose,
      );
    } finally {
      done.complete();
    }
  }
}
