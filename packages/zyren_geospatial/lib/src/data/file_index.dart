import 'dart:typed_data';
import 'resource_key.dart';
import 'store.dart';
import 'policy.dart';
import 'integrity.dart';
import 'manifest_store.dart';

final class GeoFileEntry {
  final GeoResourceKey key;
  final String checksum;
  final int size;
  final DateTime fetchedAt;
  final DateTime? expiresAt;
  final String? mediaType;
  GeoFileEntry(GeoResource value)
    : key = value.key,
      checksum = value.checksum,
      size = value.bytes.length,
      fetchedAt = value.fetchedAt,
      expiresAt = value.expiresAt,
      mediaType = value.mediaType;
  GeoFileEntry._(
    this.key,
    this.checksum,
    this.size,
    this.fetchedAt,
    this.expiresAt,
    this.mediaType,
  );
  String get filename => '${key.digest}-$checksum.blob';
  Map<String, Object?> toJson() => {
    'key': key.toJson(),
    'checksum': checksum,
    'size': size,
    'fetchedAt': fetchedAt.toIso8601String(),
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    if (mediaType != null) 'mediaType': mediaType,
  };
  factory GeoFileEntry.fromJson(Object? value) {
    final data = value as Map<String, Object?>;
    if (data.keys.any(
      (k) => !{
        'key',
        'checksum',
        'size',
        'fetchedAt',
        'expiresAt',
        'mediaType',
      }.contains(k),
    )) {
      throw const FormatException('Unknown entry field.');
    }
    final key = GeoResourceKey.fromJson(data['key'] as Map<String, Object?>);
    final checksum = data['checksum'] as String;
    final size = data['size'] as int;
    final fetched = DateTime.parse(data['fetchedAt'] as String);
    final expires = data['expiresAt'] == null
        ? null
        : DateTime.parse(data['expiresAt'] as String);
    final media = data['mediaType'] as String?;
    if (!geoDigestPattern.hasMatch(checksum) ||
        size < 0 ||
        size > 512 * 1024 * 1024 ||
        !fetched.isUtc ||
        (expires != null && !expires.isUtc) ||
        (media != null &&
            (media.length > 256 || media.contains(RegExp(r'[\r\n]'))))) {
      throw const FormatException('Invalid resource metadata.');
    }
    return GeoFileEntry._(key, checksum, size, fetched, expires, media);
  }
  GeoResource resource(Uint8List bytes) => GeoResource(
    key: key,
    bytes: bytes,
    fetchedAt: fetchedAt,
    checksum: checksum,
    expiresAt: expiresAt,
    mediaType: mediaType,
  );
}

final class GeoFileIndex {
  final Map<String, GeoFileEntry> entries;
  final Map<String, Set<String>> pins;
  final Map<String, GeoStoredManifest> records;
  int revision;
  GeoFileIndex({
    Map<String, GeoFileEntry>? entries,
    Map<String, Set<String>>? pins,
    Map<String, GeoStoredManifest>? records,
    this.revision = 0,
  }) : entries = entries ?? {},
       pins = pins ?? {},
       records = records ?? {};
  int get payloadBytes => entries.values.fold(0, (n, e) => n + e.size);
  Set<String> get pinned => {for (final values in pins.values) ...values};
  GeoFileIndex copy() => GeoFileIndex(
    entries: Map.of(entries),
    records: Map.of(records),
    revision: revision,
    pins: {for (final e in pins.entries) e.key: Set.of(e.value)},
  );
  Uint8List encode() => encodeGeoIndex({
    'schema': 2,
    'revision': revision,
    'records': {
      for (final id in records.keys.toList()..sort())
        id: {
          'revision': records[id]!.revision,
          'document': records[id]!.document,
        },
    },
    'entries': {
      for (final id in entries.keys.toList()..sort()) id: entries[id]!.toJson(),
    },
    'pins': {
      for (final id in pins.keys.toList()..sort())
        id: pins[id]!.toList()..sort(),
    },
  });
  static GeoFileIndex decode(
    Uint8List bytes, {
    required int maxEntries,
    required int maxManifests,
  }) {
    try {
      final data = decodeGeoIndex(bytes);
      if (!((data['schema'] == 1 && data.length == 3) ||
          (data['schema'] == 2 && data.length == 5))) {
        throw const FormatException('Unknown store schema.');
      }
      final rawEntries = data['entries'] as Map<String, Object?>;
      final rawPins = data['pins'] as Map<String, Object?>;
      if (rawEntries.length > maxEntries || rawPins.length > maxManifests) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      final result = GeoFileIndex();
      for (final pair in rawEntries.entries) {
        final entry = GeoFileEntry.fromJson(pair.value);
        if (entry.key.digest != pair.key) {
          throw const FormatException('Entry identity mismatch.');
        }
        result.entries[pair.key] = entry;
      }
      for (final pair in rawPins.entries) {
        validateGeoManifestId(pair.key);
        final values = (pair.value as List).cast<String>();
        if (values.length > maxEntries ||
            values.toSet().length != values.length ||
            values.any((d) => !result.entries.containsKey(d))) {
          throw const FormatException('Invalid pin set.');
        }
        result.pins[pair.key] = values.toSet();
      }
      if (data['schema'] == 2) {
        result.revision = data['revision'] as int;
        if (result.revision < 0 || result.revision > 9007199254740991) {
          throw const FormatException('Invalid manifest revision.');
        }
        final records = data['records'] as Map<String, Object?>;
        if (records.length > maxManifests) {
          throw const GeoDataException(GeoDataError.budgetExceeded);
        }
        for (final entry in records.entries) {
          validateGeoManifestId(entry.key);
          final value = entry.value as Map<String, Object?>;
          final revision = value['revision'] as int;
          if (value.length != 2 ||
              revision < 1 ||
              revision > result.revision ||
              !result.pins.containsKey(entry.key)) {
            throw const FormatException('Invalid manifest record.');
          }
          result.records[entry.key] = GeoStoredManifest(
            revision: revision,
            document: value['document'] as Map<String, Object?>,
            digests: result.pins[entry.key]!,
          );
        }
      }
      return result;
    } on GeoDataException {
      rethrow;
    } catch (error) {
      throw GeoDataException(GeoDataError.corrupt, cause: error);
    }
  }
}

void validateGeoManifestId(String id) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(id) ||
      id == '.' ||
      id == '..') {
    throw ArgumentError('Invalid offline manifest ID.');
  }
}
