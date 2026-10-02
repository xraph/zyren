import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';

/// Limits encoded payloads and the serialized container, not process memory.
final class PipelineLimits {
  final int maxSources, maxSourceBytes, maxTotalBytes, maxArchiveBytes;
  const PipelineLimits({
    this.maxSources = 128,
    this.maxSourceBytes = 32 * 1024 * 1024,
    this.maxTotalBytes = 128 * 1024 * 1024,
    this.maxArchiveBytes = 192 * 1024 * 1024,
  });

  void validate() {
    for (final value in [
      maxSources,
      maxSourceBytes,
      maxTotalBytes,
      maxArchiveBytes,
    ]) {
      RangeError.checkValueInInterval(value, 1, 0x7fffffff);
    }
  }
}

/// Source-owned identity. [revision] is distinct from the bundle content hash.
final class PipelineSource {
  final String sourceId, revision;
  final Uri uri;
  PipelineSource({
    required this.sourceId,
    required this.revision,
    required this.uri,
  }) {
    _text(sourceId);
    _text(revision);
    _uri(uri);
  }
}

/// Original source bytes and their transport location, retained without rewriting.
final class PipelineResource {
  final PipelineSource source;
  final Uri effectiveUri;
  final String? mediaType;
  final Uint8List bytes;
  final String digest;
  PipelineResource._(this.source, ResolvedSource resolved)
    : effectiveUri = resolved.effectiveUri,
      mediaType = resolved.mediaType,
      bytes = resolved.bytes,
      digest = _hash(resolved.bytes) {
    _uri(effectiveUri);
    if (mediaType != null) _text(mediaType!);
  }

  Map<String, Object?> _manifest() => {
    'sourceId': source.sourceId,
    'revision': source.revision,
    'uri': source.uri.toString(),
    'effectiveUri': effectiveUri.toString(),
    'mediaType': mediaType,
    'length': bytes.length,
    'sha256': digest,
  };
}

/// Immutable original-byte bundle. Decoding verifies integrity, not authenticity.
final class PipelineBundle {
  static const schemaVersion = 1;
  final String entrySourceId, version;
  final List<PipelineResource> resources;
  final int byteLength;

  PipelineBundle._(this.entrySourceId, List<PipelineResource> values)
    : resources = List.unmodifiable(values),
      byteLength = values.fold(0, (sum, r) => sum + r.bytes.length),
      version = _hash(
        utf8.encode(jsonEncode(_manifest(entrySourceId, values))),
      );

  PipelineResource resource(String sourceId) {
    for (final resource in resources) {
      if (resource.source.sourceId == sourceId) return resource;
    }
    throw ArgumentError.value(sourceId, 'sourceId', 'Source is not bundled.');
  }

  /// Pins both root and dependencies to this immutable bundle snapshot.
  AssetRequest<T> request<T extends Object>(
    AssetLoader<T> loader, {
    String? sourceId,
  }) => AssetRequest<T>(
    uri: resource(sourceId ?? entrySourceId).source.uri,
    loader: loader,
    version: version,
  );

  AssetRequest<ModelAsset> gltfRequest({
    String? sourceId,
    GltfOptions options = const GltfOptions(),
  }) => Gltf.uri(
    resource(sourceId ?? entrySourceId).source.uri,
    options: options,
    version: version,
  );

  /// Reuses host codecs, limits and policy. Reads never fall back to the network.
  AssetScope open({AssetServices services = const AssetServices()}) =>
      AssetScope(
        services: AssetServices(
          resolver: _BundleResolver(this),
          imageDecoder: services.imageDecoder,
          textureDecoder: services.textureDecoder,
          bufferDecoder: services.bufferDecoder,
          meshDecoder: services.meshDecoder,
          hdrImageDecoder: services.hdrImageDecoder,
          tangentGenerator: services.tangentGenerator,
          limits: services.limits,
          policy: services.policy,
          onCleanupError: services.onCleanupError,
        ),
      );

  /// Decodes with the existing glTF loader and closes all temporary assets.
  /// Returned warnings remain visible to the caller; missing codecs fail normally.
  Future<List<SceneIssue>> validateGltf({
    AssetServices services = const AssetServices(),
    GltfOptions options = const GltfOptions(),
    String? sourceId,
    LoadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final scope = open(services: services);
    final task = scope.load(gltfRequest(sourceId: sourceId, options: options));
    final registration = cancellation?.onCancel(task.cancel);
    try {
      final model = await task.result;
      cancellation?.throwIfCancelled();
      return List.unmodifiable(model.issues);
    } finally {
      registration?.dispose();
      await scope.close();
    }
  }

  Uint8List encode({PipelineLimits limits = const PipelineLimits()}) {
    _checkResources(resources, entrySourceId, limits);
    // Reject before allocating base64 strings for obviously oversized containers.
    final base64Length = resources.fold<int>(
      0,
      (sum, r) => sum + 4 * ((r.bytes.length + 2) ~/ 3),
    );
    _budget(base64Length <= limits.maxArchiveBytes);
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          ..._manifest(entrySourceId, resources),
          'version': version,
          'payloads': [for (final r in resources) base64Encode(r.bytes)],
        }),
      ),
    );
    _budget(bytes.length <= limits.maxArchiveBytes);
    return bytes;
  }

  factory PipelineBundle.decode(
    Uint8List bytes, {
    PipelineLimits limits = const PipelineLimits(),
  }) {
    limits.validate();
    _budget(bytes.length <= limits.maxArchiveBytes);
    try {
      final root = jsonDecode(utf8.decode(bytes));
      if (root is! Map<String, dynamic> ||
          root['schemaVersion'] != schemaVersion ||
          root['processing'] != 'original' ||
          root['entrySourceId'] is! String ||
          root['version'] is! String ||
          root['resources'] is! List ||
          root['payloads'] is! List) {
        throw const FormatException('Unsupported or invalid pipeline bundle.');
      }
      final entries = root['resources'] as List;
      final payloads = root['payloads'] as List;
      _budget(entries.length <= limits.maxSources);
      if (payloads.length != entries.length) {
        throw const FormatException('Resource and payload counts differ.');
      }
      final values = <PipelineResource>[];
      var total = 0;
      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i] as Map<String, dynamic>;
        final length = entry['length'] as int;
        final encoded = payloads[i] as String;
        final remaining = math.min(
          limits.maxSourceBytes,
          limits.maxTotalBytes - total,
        );
        _budget(length >= 0 && length <= remaining);
        _budget(encoded.length <= 4 * ((remaining + 2) ~/ 3));
        final data = base64Decode(encoded);
        _budget(data.length <= remaining);
        if (data.length != length || _hash(data) != entry['sha256']) {
          throw const FormatException(
            'Resource length or digest does not match.',
          );
        }
        total += data.length;
        values.add(
          PipelineResource._(
            PipelineSource(
              sourceId: entry['sourceId'] as String,
              revision: entry['revision'] as String,
              uri: Uri.parse(entry['uri'] as String),
            ),
            ResolvedSource(
              effectiveUri: Uri.parse(entry['effectiveUri'] as String),
              mediaType: entry['mediaType'] as String?,
              bytes: data,
            ),
          ),
        );
      }
      final entryId = root['entrySourceId'] as String;
      _checkResources(values, entryId, limits);
      final bundle = PipelineBundle._(entryId, values);
      if (bundle.version != root['version']) {
        throw const FormatException('Bundle manifest digest does not match.');
      }
      return bundle;
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid bundle field: $error');
    } on TypeError {
      throw const FormatException('Invalid bundle field type.');
    }
  }
}

/// Reads a declared resource set serially with cancellation and aggregate budgets.
/// Use [PipelineBundle.validateGltf] before publishing a glTF bundle.
final class PipelineBuilder {
  final ByteSourceResolver resolver;
  final SourcePolicy policy;
  final PipelineLimits limits;
  const PipelineBuilder({
    required this.resolver,
    this.policy = const SourcePolicy(),
    this.limits = const PipelineLimits(),
  });

  Future<PipelineBundle> build({
    required String entrySourceId,
    required List<PipelineSource> sources,
    LoadCancellation? cancellation,
  }) async {
    limits.validate();
    // Copy caller-owned input before the first await.
    final ordered = List<PipelineSource>.of(sources)
      ..sort((a, b) => a.sourceId.compareTo(b.sourceId));
    _budget(ordered.length <= limits.maxSources);
    _checkSources(ordered, entrySourceId);
    final token = cancellation ?? const _NoCancellation();
    final values = <PipelineResource>[];
    var total = 0;
    for (final source in ordered) {
      token.throwIfCancelled();
      policy.validate(source.uri, source.uri);
      final remaining = math.min(
        limits.maxSourceBytes,
        limits.maxTotalBytes - total,
      );
      _budget(remaining > 0);
      final resolved = await resolver.read(
        source.uri,
        SourceReadContext(
          maxBytes: remaining,
          cancellation: token,
          policy: policy,
          onProgress: (_, _) {},
        ),
      );
      token.throwIfCancelled();
      policy.validate(source.uri, resolved.effectiveUri);
      _budget(resolved.bytes.length <= remaining);
      values.add(PipelineResource._(source, resolved));
      total += resolved.bytes.length;
    }
    _checkResources(values, entrySourceId, limits);
    return PipelineBundle._(entrySourceId, values);
  }
}

final class _BundleResolver implements ByteSourceResolver {
  final Map<Uri, PipelineResource> _sources;
  _BundleResolver(PipelineBundle bundle)
    : _sources = {for (final r in bundle.resources) r.source.uri: r};

  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    context.policy.validate(uri, uri);
    final resource = _sources[uri];
    if (resource == null) {
      throw AssetLoadException(
        AssetLoadError.sourceUnavailable,
        'The requested source is not in this bundle.',
        sourceUri: uri,
      );
    }
    context.policy.validate(uri, resource.effectiveUri);
    context.reportProgress(resource.bytes.length, resource.bytes.length);
    return ResolvedSource(
      effectiveUri: resource.effectiveUri,
      bytes: resource.bytes,
      mediaType: resource.mediaType,
    );
  }
}

Map<String, Object?> _manifest(
  String entryId,
  List<PipelineResource> resources,
) => {
  'schemaVersion': PipelineBundle.schemaVersion,
  'processing': 'original',
  'entrySourceId': entryId,
  'resources': [for (final r in resources) r._manifest()],
};

void _checkSources(List<PipelineSource> sources, String entryId) {
  final ids = <String>{}, uris = <Uri>{};
  for (final source in sources) {
    if (!ids.add(source.sourceId) || !uris.add(source.uri)) {
      throw const FormatException('Duplicate source ID or requested URI.');
    }
  }
  if (!ids.contains(entryId)) {
    throw const FormatException('Entry source is not in the bundle.');
  }
}

void _checkResources(
  List<PipelineResource> values,
  String entryId,
  PipelineLimits limits,
) {
  limits.validate();
  _budget(values.length <= limits.maxSources);
  _checkSources([for (final r in values) r.source], entryId);
  var total = 0;
  String? previous;
  for (final resource in values) {
    final id = resource.source.sourceId;
    if (previous != null && previous.compareTo(id) >= 0) {
      throw const FormatException('Resources must be sorted by source ID.');
    }
    previous = id;
    total += resource.bytes.length;
    _budget(
      resource.bytes.length <= limits.maxSourceBytes &&
          total <= limits.maxTotalBytes,
    );
  }
}

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

void _text(String text) {
  if (text.trim().isEmpty || text.length > 2048 || text.contains('\u0000')) {
    throw const FormatException(
      'Source text must contain 1 to 2048 characters.',
    );
  }
}

void _uri(Uri uri) {
  _text(uri.toString());
  if (!uri.hasScheme || uri.hasFragment || uri.userInfo.isNotEmpty) {
    throw const FormatException(
      'Source URI must be absolute, without credentials or fragment.',
    );
  }
}

void _budget(bool valid) {
  if (!valid) {
    throw const FormatException(
      'Pipeline bundle exceeds its byte or source budget.',
    );
  }
}

final class _NoCancellation implements LoadCancellation {
  const _NoCancellation();
  @override
  bool get isCancelled => false;
  @override
  void throwIfCancelled() {}
  @override
  Registration onCancel(void Function() callback) => Registration(() {});
}
