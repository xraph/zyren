import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'checked.dart';

bool isDataUri(String value) =>
    value.length >= 5 && value.substring(0, 5).toLowerCase() == 'data:';

Uint8List decodeDataUri(
  String uri,
  int maxBytes,
  Set<String> mediaTypes,
  String path,
) {
  try {
    final comma = uri.indexOf(',');
    if (!isDataUri(uri) || comma < 0 || comma > 1024) {
      fail(path, 'Malformed data URI header.');
    }
    final header = uri.substring(5, comma).split(';');
    if (!mediaTypes.contains(header.first.toLowerCase()) ||
        header.last.toLowerCase() != 'base64') {
      fail(path, 'Data URI needs an accepted media type and base64 encoding.');
    }
    final normalized = base64.normalize(uri.substring(comma + 1));
    final padding = normalized.endsWith('==')
        ? 2
        : normalized.endsWith('=')
        ? 1
        : 0;
    final length = normalized.length ~/ 4 * 3 - padding;
    if (length > maxBytes) {
      fail(
        path,
        'Embedded data exceeds its byte budget.',
        AssetLoadError.limitExceeded,
      );
    }
    return base64.decode(normalized).asUnmodifiableView();
  } on FormatException {
    fail(path, 'Malformed base64 data URI.');
  }
}
