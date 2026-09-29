import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'checked.dart';
import 'document.dart';

const meshoptExtension = 'EXT_meshopt_compression';

final class _CompressedView {
  final int buffer, offset, length;
  final BufferDecodeOptions options;
  const _CompressedView(this.buffer, this.offset, this.length, this.options);
}

/// Validates the source and fallback layout before fetching or decoding buffers.
final class MeshoptViews {
  final Map<int, _CompressedView> _views;
  final Set<int> skippedBuffers;
  MeshoptViews._(this._views, this.skippedBuffers);

  static MeshoptViews inspect(GltfDocument document) {
    final root = document.root;
    final buffers = array(field(root, 'buffers', const []), 'buffers');
    final views = array(field(root, 'bufferViews', const []), 'bufferViews');
    final declared = array(
      field(root, 'extensionsUsed', const []),
      'extensionsUsed',
    ).contains(meshoptExtension);
    final required = array(
      field(root, 'extensionsRequired', const []),
      'extensionsRequired',
    ).contains(meshoptExtension);
    final lengths = <int>[];
    final skipped = <int>{};
    for (var i = 0; i < buffers.length; i++) {
      final path = 'buffers[$i]', buffer = object(buffers[i], 'buffers[$i]');
      lengths.add(integer(buffer['byteLength'], '$path.byteLength', min: 1));
      final extension = _extension(buffer, path);
      final fallback =
          extension != null &&
          boolean(
            field(extension, 'fallback', false),
            '$path.extensions.$meshoptExtension.fallback',
          );
      final placeholder =
          !buffer.containsKey('uri') && (i != 0 || document.binary == null);
      if (placeholder && (!declared || !required)) {
        fail('$path.uri', 'A placeholder buffer requires meshopt compression.');
      }
      if (extension != null && !declared) {
        fail(
          '$path.extensions',
          'Meshopt compression must be declared in extensionsUsed.',
        );
      }
      if (fallback || placeholder) skipped.add(i);
    }
    final compressed = <int, _CompressedView>{};
    for (var i = 0; i < views.length; i++) {
      final path = 'bufferViews[$i]',
          view = object(views[i], 'bufferViews[$i]');
      final parentBuffer = index(
        view['buffer'],
        buffers.length,
        '$path.buffer',
      );
      final parentOffset = integer(
        field(view, 'byteOffset', 0),
        '$path.byteOffset',
      );
      final parentLength = integer(
        view['byteLength'],
        '$path.byteLength',
        min: 1,
      );
      if (parentOffset > lengths[parentBuffer] ||
          parentLength > lengths[parentBuffer] - parentOffset) {
        fail(path, 'Buffer view exceeds its declared fallback buffer.');
      }
      final extension = _extension(view, path);
      if (extension == null) {
        if (skipped.contains(parentBuffer)) {
          fail(
            path,
            'An ordinary view cannot reference a meshopt fallback buffer.',
          );
        }
        continue;
      }
      if (!declared) {
        fail(
          '$path.extensions',
          'Meshopt compression must be declared in extensionsUsed.',
        );
      }
      final extPath = '$path.extensions.$meshoptExtension';
      final buffer = index(
        extension['buffer'],
        buffers.length,
        '$extPath.buffer',
      );
      if (skipped.contains(buffer)) {
        fail(
          '$extPath.buffer',
          'Compressed data cannot reference a fallback buffer.',
        );
      }
      final offset = integer(
        field(extension, 'byteOffset', 0),
        '$extPath.byteOffset',
      );
      final length = integer(
        extension['byteLength'],
        '$extPath.byteLength',
        min: 1,
      );
      if (offset > lengths[buffer] || length > lengths[buffer] - offset) {
        fail(extPath, 'Compressed view exceeds its source buffer.');
      }
      final mode = switch (extension['mode']) {
        'ATTRIBUTES' => BufferDecodeMode.attributes,
        'TRIANGLES' => BufferDecodeMode.triangles,
        'INDICES' => BufferDecodeMode.indices,
        _ => fail('$extPath.mode', 'Unknown meshopt compression mode.'),
      };
      final filter = switch (field(extension, 'filter', 'NONE')) {
        'NONE' => BufferDecodeFilter.none,
        'OCTAHEDRAL' => BufferDecodeFilter.octahedral,
        'QUATERNION' => BufferDecodeFilter.quaternion,
        'EXPONENTIAL' => BufferDecodeFilter.exponential,
        _ => fail('$extPath.filter', 'Unknown meshopt filter.'),
      };
      final options = BufferDecodeOptions(
        encoding: BufferEncoding.meshopt,
        mode: mode,
        filter: filter,
        count: integer(extension['count'], '$extPath.count', min: 1),
        stride: integer(
          extension['byteStride'],
          '$extPath.byteStride',
          min: 1,
          max: 256,
        ),
      );
      try {
        options.validate();
      } on BufferDecodeException catch (error) {
        fail(
          extPath,
          error.message,
          error.code == BufferDecodeError.limitExceeded
              ? AssetLoadError.limitExceeded
              : AssetLoadError.invalidData,
        );
      }
      if (parentLength != options.decodedByteLength) {
        fail(
          '$path.byteLength',
          'View length must equal the decoded count times stride.',
        );
      }
      if (view.containsKey('byteStride') &&
          integer(view['byteStride'], '$path.byteStride') != options.stride) {
        fail(
          '$path.byteStride',
          'View stride must match the compressed layout.',
        );
      }
      compressed[i] = _CompressedView(buffer, offset, length, options);
    }
    return MeshoptViews._(compressed, skipped);
  }

  Future<(Map<String, Object?>, List<Uint8List>)> decode(
    GltfDocument document,
    List<Uint8List> sources,
    AssetDecodeContext context,
  ) async {
    final root = document.root;
    final descriptions = array(field(root, 'buffers', const []), 'buffers');
    final originalViews = array(
      field(root, 'bufferViews', const []),
      'bufferViews',
    );
    final buffers = <Uint8List>[], bufferDescriptions = <Object?>[];
    final remap = <int, int>{};
    for (var i = 0; i < descriptions.length; i++) {
      if (skippedBuffers.contains(i)) continue;
      remap[i] = buffers.length;
      buffers.add(sources[i]);
      bufferDescriptions.add(descriptions[i]);
    }
    final views = <Object?>[];
    for (var i = 0; i < originalViews.length; i++) {
      context.cancellation.throwIfCancelled();
      final view = Map<String, Object?>.of(
        object(originalViews[i], 'bufferViews[$i]'),
      );
      final compressed = _views[i];
      if (compressed == null) {
        view['buffer'] = remap[view['buffer']];
      } else {
        final source = sources[compressed.buffer];
        var bytes = await context.decodeBuffer(
          Uint8List.sublistView(
            source,
            compressed.offset,
            compressed.offset + compressed.length,
          ),
          options: compressed.options,
          fieldPath: 'bufferViews[$i].extensions.$meshoptExtension',
        );
        // Preserve the original offset's alignment so ordinary accessor checks
        // still catch malformed layouts after replacing a compressed view.
        final padding =
            integer(
              field(view, 'byteOffset', 0),
              'bufferViews[$i].byteOffset',
            ) %
            4;
        if (padding != 0) {
          context.reserveDecodedBytes(padding, fieldPath: 'bufferViews[$i]');
          bytes = Uint8List(bytes.length + padding)..setAll(padding, bytes);
        }
        view['buffer'] = buffers.length;
        view['byteOffset'] = padding;
        final extensions = Map<String, Object?>.of(
          object(view['extensions'], 'bufferViews[$i].extensions'),
        )..remove(meshoptExtension);
        if (extensions.isEmpty) {
          view.remove('extensions');
        } else {
          view['extensions'] = extensions;
        }
        bufferDescriptions.add({'byteLength': bytes.length});
        buffers.add(bytes);
      }
      views.add(view);
    }
    return (
      {
        ...root,
        if (descriptions.isNotEmpty) 'buffers': bufferDescriptions,
        if (originalViews.isNotEmpty) 'bufferViews': views,
      },
      List<Uint8List>.unmodifiable(buffers),
    );
  }
}

Map<String, Object?>? _extension(Map<String, Object?> value, String path) {
  if (!value.containsKey('extensions')) return null;
  final extensions = object(value['extensions'], '$path.extensions');
  return extensions.containsKey(meshoptExtension)
      ? object(
          extensions[meshoptExtension],
          '$path.extensions.$meshoptExtension',
        )
      : null;
}
