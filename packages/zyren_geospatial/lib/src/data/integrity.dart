import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'file_lock.dart';
import 'policy.dart';

final geoDigestPattern = RegExp(r'^[a-f0-9]{64}$');

Uint8List encodeGeoIndex(Map<String, Object?> body) {
  final encoded = jsonEncode(body);
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'checksum': sha256.convert(utf8.encode(encoded)).toString(),
        'body': encoded,
      }),
    ),
  );
}

Map<String, Object?> decodeGeoIndex(Uint8List bytes) {
  try {
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final body = envelope['body'] as String;
    if (envelope.length != 2 ||
        envelope['checksum'] != sha256.convert(utf8.encode(body)).toString()) {
      throw const FormatException('Invalid metadata digest.');
    }
    return jsonDecode(body) as Map<String, Object?>;
  } catch (error) {
    throw GeoDataException(GeoDataError.corrupt, cause: error);
  }
}

Future<Uint8List> readGeoFile(
  File file,
  int maxBytes,
  LoadCancellation token,
) async {
  await regularFileOrAbsent(file);
  if (await file.length() > maxBytes) {
    throw const GeoDataException(GeoDataError.budgetExceeded);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    token.throwIfCancelled();
    if (bytes.length + chunk.length > maxBytes) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    bytes.add(chunk);
  }
  token.throwIfCancelled();
  return bytes.takeBytes();
}
