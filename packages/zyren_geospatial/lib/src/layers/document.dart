import 'dart:convert';

/// Copy only bounded JSON data. Source credentials belong in transport services.
Map<String, Object?> copyLayerDocument(
  Map<String, Object?> input, {
  int maxBytes = 8 * 1024 * 1024,
  bool immutable = true,
}) {
  var nodes = 0, measuredBytes = 0;
  void admit(int bytes) {
    measuredBytes += bytes;
    if (measuredBytes > maxBytes) {
      throw ArgumentError('Layer document exceeds its byte budget.');
    }
  }

  const secrets = {
    'password',
    'passwd',
    'secret',
    'clientsecret',
    'token',
    'accesstoken',
    'refreshtoken',
    'authorization',
    'apikey',
    'credential',
    'credentials',
    'signature',
    'xamzsignature',
    'xamzcredential',
    'xamzsecuritytoken',
  };
  bool sensitive(String value) =>
      secrets.contains(value.toLowerCase().replaceAll(RegExp('[^a-z]'), ''));
  Object? copy(Object? value, int depth) {
    if (++nodes > 100000 || depth > 32) {
      throw ArgumentError('Layer document exceeds structural limits.');
    }
    admit(1);
    if (value == null || value is bool || value is int) {
      admit(value.toString().length);
      return value;
    }
    if (value is double) {
      if (!value.isFinite) throw ArgumentError('Layer numbers must be finite.');
      return value;
    }
    if (value is String) {
      if (value.length > maxBytes) {
        throw ArgumentError('Layer string exceeds the document budget.');
      }
      admit(utf8.encode(value).length + 2);
      final uri = Uri.tryParse(value);
      if (uri != null &&
          (uri.userInfo.isNotEmpty ||
              uri.queryParameters.keys.any(sensitive))) {
        throw ArgumentError(
          'Do not persist credential-bearing resource addresses.',
        );
      }
      return value;
    }
    if (value is List) {
      final result = value.map((entry) => copy(entry, depth + 1)).toList();
      return immutable ? List<Object?>.unmodifiable(result) : result;
    }
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || sensitive(key)) {
          throw ArgumentError(
            'Layer data needs public string keys without credentials.',
          );
        }
        if (key.length > maxBytes) {
          throw ArgumentError('Layer key exceeds the document budget.');
        }
        admit(utf8.encode(key).length + 3);
        result[key] = copy(entry.value, depth + 1);
      }
      return immutable ? Map<String, Object?>.unmodifiable(result) : result;
    }
    throw ArgumentError(
      'Layer data must be JSON, without live resource handles.',
    );
  }

  final result = copy(input, 0) as Map<String, Object?>;
  if (utf8.encode(jsonEncode(result)).length > maxBytes) {
    throw ArgumentError('Layer document exceeds $maxBytes bytes.');
  }
  return result;
}
