import 'dart:typed_data';
import 'package:flutter/services.dart';

Map<String, Object> textureFormatsReply(MethodCall call, {int mask = 7}) {
  final request = ByteData.sublistView(
    (call.arguments as Map)['bytes'] as Uint8List,
  );
  final reply = ByteData(28)
    ..setUint32(0, 2, Endian.little)
    ..setUint64(8, request.getUint64(8, Endian.little), Endian.little)
    ..setUint64(16, 4, Endian.little)
    ..setUint32(24, mask, Endian.little);
  return {'status': 0, 'bytes': reply.buffer.asUint8List()};
}
