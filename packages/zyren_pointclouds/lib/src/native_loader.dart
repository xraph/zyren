import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'bindings.dart';
import 'cloud.dart';

/// Identifies LAS/LAZ/E57 by file signature and decodes on a worker isolate.
/// Cancellation reaches the native record loop and completion drains that worker.
final class NativePointCloudLoader extends AssetLoader<PointCloudData> {
  final String sourceVersion;
  final PointCloudLimits limits;
  const NativePointCloudLoader({
    required this.sourceVersion,
    this.limits = const PointCloudLimits(),
  });
  @override
  Object get cacheKey => (
    sourceVersion,
    limits.maxPoints,
    limits.maxSourceBytes,
    limits.maxCoordinateBytes,
    limits.maxAttributeBytes,
    limits.maxMetadataBytes,
    limits.maxDecodedBytes,
  );
  @override
  Future<DecodedAsset<PointCloudData>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final data = await parse(
      source.bytes,
      sourceUri: context.sourceUri,
      cancellation: context.cancellation,
      reserveDecodedBytes: context.reserveDecodedBytes,
    );
    return DecodedAsset(create: () => data, release: (_) {});
  }

  Future<PointCloudData> parse(
    Uint8List bytes, {
    required Uri sourceUri,
    LoadCancellation? cancellation,
    void Function(int)? reserveDecodedBytes,
  }) async {
    limits.validate();
    cancellation?.throwIfCancelled();
    if (bytes.length > limits.maxSourceBytes) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'Point source exceeds its byte budget.',
      );
    }
    // Reserve before native allocation. The context accounts an upper bound;
    // payloadBytes reports the actual retained payload after decoding.
    reserveDecodedBytes?.call(limits.maxDecodedBytes);
    final job = pointsJobCreate();
    final registration = cancellation?.onCancel(() => pointsJobCancel(job));
    final transfer = TransferableTypedData.fromList([bytes]);
    final maxPoints = math.min(
      limits.maxPoints,
      limits.maxCoordinateBytes ~/ 24,
    );
    final maxBytes = limits.maxDecodedBytes;
    try {
      final result = await Isolate.run(
        () => _decode(job, transfer, maxPoints, maxBytes),
      );
      cancellation?.throwIfCancelled();
      final output = result.materialize().asUint8List();
      if (output[0] != 0) {
        if (output[0] == 3) throw LoadCancelled();
        throw AssetLoadException(
          output[0] == 2
              ? AssetLoadError.limitExceeded
              : AssetLoadError.invalidData,
          utf8.decode(output.sublist(1), allowMalformed: true),
        );
      }
      final view = ByteData.sublistView(output);
      final count = view.getUint32(1, Endian.little),
          metaLength = view.getUint32(5, Endian.little);
      limits.checkCount(count);
      final metadata = _json(output, 13, metaLength);
      metadata['skippedInvalidRecords'] = view.getUint32(9, Endian.little);
      var offset = 13 + metaLength, attributeBytes = 0;
      final points = <Vec3>[],
          ordinals = <int>[],
          attributes = <Map<String, Object?>>[];
      for (var i = 0; i < count; i++) {
        cancellation?.throwIfCancelled();
        points.add(
          Vec3(
            view.getFloat64(offset, Endian.little),
            view.getFloat64(offset + 8, Endian.little),
            view.getFloat64(offset + 16, Endian.little),
          ),
        );
        ordinals.add(view.getUint64(offset + 24, Endian.little));
        final scan = view.getUint32(offset + 32, Endian.little),
            len = view.getUint32(offset + 36, Endian.little);
        attributeBytes += len;
        if (attributeBytes > limits.maxAttributeBytes) {
          throw AssetLoadException(
            AssetLoadError.limitExceeded,
            'Point attributes exceed their budget.',
          );
        }
        final attrs = _json(output, offset + 40, len)..['scanIndex'] = scan;
        attributes.add(attrs);
        offset += 40 + len;
        if (i % 1024 == 0) await Future<void>.delayed(Duration.zero);
      }
      if (offset != output.length) {
        throw StateError('Native point decoder returned an invalid payload.');
      }
      cancellation?.throwIfCancelled();
      return PointCloudData(
        sourceUri: sourceUri,
        sourceVersion: sourceVersion,
        points: points,
        recordIndices: ordinals,
        attributes: attributes,
        metadata: metadata,
        limits: limits,
      );
    } finally {
      registration?.dispose();
      pointsJobFree(job);
    }
  }
}

Map<String, Object?> _json(Uint8List b, int start, int length) =>
    (jsonDecode(utf8.decode(Uint8List.sublistView(b, start, start + length)))
            as Map)
        .cast<String, Object?>();
TransferableTypedData _decode(
  int job,
  TransferableTypedData transfer,
  int maxPoints,
  int maxBytes,
) {
  final bytes = transfer.materialize().asUint8List();
  final input = calloc<Uint8>(bytes.length), length = calloc<Size>();
  Pointer<Uint8> output = nullptr;
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    output = pointsDecode(
      job,
      input,
      bytes.length,
      maxPoints,
      maxBytes,
      length,
    );
    return TransferableTypedData.fromList([output.asTypedList(length.value)]);
  } finally {
    if (output != nullptr) pointsFree(output, length.value);
    calloc.free(input);
    calloc.free(length);
  }
}
