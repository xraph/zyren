import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Public dataset identity. Transport addresses and credentials stay in fetchers.
final class GeoResourceKey {
  final String sourceId,
      sourceVersion,
      authorizationPartition,
      address,
      representation;
  final int decoderVersion;
  final String? projection, timeSlice, derivation;
  late final String digest = sha256
      .convert(utf8.encode(jsonEncode(toJson())))
      .toString();
  GeoResourceKey({
    required this.sourceId,
    required this.sourceVersion,
    required this.authorizationPartition,
    required this.address,
    required this.representation,
    required this.decoderVersion,
    this.projection,
    this.timeSlice,
    this.derivation,
  }) {
    final fields = [
      sourceId,
      sourceVersion,
      authorizationPartition,
      address,
      representation,
      projection,
      timeSlice,
      derivation,
    ];
    final characters = RegExp(r'^[A-Za-z0-9._:/~+-]+$');
    if (decoderVersion < 1 ||
        decoderVersion > 2147483647 ||
        fields.whereType<String>().any(
          (v) =>
              v.isEmpty ||
              v.length > 1024 ||
              !characters.hasMatch(v) ||
              v.contains('://'),
        ) ||
        address.startsWith('/') ||
        address.contains(':') ||
        address.split('/').any((v) => v.isEmpty || v == '.' || v == '..') ||
        utf8.encode(jsonEncode(toJson())).length > 4096) {
      throw ArgumentError(
        'Resource keys require bounded public identifiers and a relative logical address.',
      );
    }
  }
  Map<String, Object?> toJson() => {
    'schema': 1,
    'sourceId': sourceId,
    'sourceVersion': sourceVersion,
    'authorizationPartition': authorizationPartition,
    'address': address,
    'representation': representation,
    'decoderVersion': decoderVersion,
    'projection': projection,
    'timeSlice': timeSlice,
    'derivation': derivation,
  };
  factory GeoResourceKey.fromJson(Map<String, Object?> value) {
    const names = {
      'schema',
      'sourceId',
      'sourceVersion',
      'authorizationPartition',
      'address',
      'representation',
      'decoderVersion',
      'projection',
      'timeSlice',
      'derivation',
    };
    if (value['schema'] != 1 ||
        value.keys.toSet().difference(names).isNotEmpty) {
      throw const FormatException('Unsupported geographic resource key.');
    }
    try {
      return GeoResourceKey(
        sourceId: value['sourceId'] as String,
        sourceVersion: value['sourceVersion'] as String,
        authorizationPartition: value['authorizationPartition'] as String,
        address: value['address'] as String,
        representation: value['representation'] as String,
        decoderVersion: value['decoderVersion'] as int,
        projection: value['projection'] as String?,
        timeSlice: value['timeSlice'] as String?,
        derivation: value['derivation'] as String?,
      );
    } catch (_) {
      throw const FormatException('Invalid geographic resource key.');
    }
  }
  @override
  bool operator ==(Object other) =>
      other is GeoResourceKey && digest == other.digest;
  @override
  int get hashCode => digest.hashCode;
  @override
  String toString() => 'GeoResourceKey($digest)';
}
