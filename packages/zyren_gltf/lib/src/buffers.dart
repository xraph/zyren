import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'checked.dart';
import 'document.dart';
import 'data_uri.dart';
import 'worker.dart';

Future<List<Uint8List>> resolveBuffers(
  GltfDocument document,
  AssetDecodeContext context,
  Uri baseUri, {
  Set<int> skippedBuffers = const {},
}) async {
  final descriptions = array(
    field(document.root, 'buffers', const []),
    'buffers',
  );
  final buffers = <Uint8List>[];
  for (var i = 0; i < descriptions.length; i++) {
    context.cancellation.throwIfCancelled();
    final path = 'buffers[$i]',
        description = object(descriptions[i], 'buffers[$i]');
    final length = integer(
      description['byteLength'],
      '$path.byteLength',
      min: 1,
    );
    if (skippedBuffers.contains(i)) {
      buffers.add(Uint8List(0));
      continue;
    }
    if (length > context.limits.maxSourceBytes) {
      fail(
        '$path.byteLength',
        'Buffer exceeds the source limit.',
        AssetLoadError.limitExceeded,
      );
    }
    late final Uint8List bytes;
    if (!description.containsKey('uri')) {
      final binary = document.binary;
      if (i != 0 || binary == null) {
        fail('$path.uri', 'Only the first GLB buffer can omit its URI.');
      }
      if (length > binary.length ||
          binary.length - length > 3 ||
          binary.skip(length).any((value) => value != 0)) {
        fail(
          '$path.byteLength',
          'GLB binary length or padding does not match the buffer.',
        );
      }
      bytes = binary;
    } else {
      final uri = string(description['uri'], '$path.uri');
      if (uri.isEmpty) fail('$path.uri', 'Buffer URI cannot be empty.');
      if (isDataUri(uri)) {
        final available = context.limits.maxDecodedBytes - context.decodedBytes;
        bytes = await GltfWorkers.dataUri(
          uri,
          available < context.limits.maxSourceBytes
              ? available
              : context.limits.maxSourceBytes,
          const {'application/octet-stream', 'application/gltf-buffer'},
          context.cancellation,
          '$path.uri',
        );
        context.reserveDecodedBytes(bytes.length, fieldPath: '$path.uri');
      } else {
        bytes = (await context.readReference(
          uri,
          relativeTo: baseUri,
          fieldPath: '$path.uri',
        )).bytes;
      }
      if (bytes.length < length) {
        fail(
          '$path.byteLength',
          'Buffer source is shorter than its declared length.',
        );
      }
    }
    buffers.add(Uint8List.sublistView(bytes, 0, length).asUnmodifiableView());
  }
  return List.unmodifiable(buffers);
}
