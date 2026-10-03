import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'bundle.dart';
import 'incremental.dart';

/// Saved source identity pinned to one immutable bundle and resource digest.
/// The URI is provenance, never a request to fetch outside the bundle.
final class PipelineAssetReference {
  static const schemaVersion = 1;
  final String bundleVersion, sourceId, sourceRevision, sha256;
  final Uri uri;
  PipelineAssetReference({
    required this.bundleVersion,
    required this.sourceId,
    required this.sourceRevision,
    required this.sha256,
    required this.uri,
  }) {
    PipelineSource(sourceId: sourceId, revision: sourceRevision, uri: uri);
    if (![
      bundleVersion,
      sha256,
    ].every((value) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value))) {
      throw ArgumentError(
        'Asset references require bundle and resource SHA-256 digests.',
      );
    }
  }
  factory PipelineAssetReference.fromBundle(
    PipelineBundle bundle, {
    String? sourceId,
  }) {
    final resource = bundle.resource(sourceId ?? bundle.entrySourceId);
    return PipelineAssetReference(
      bundleVersion: bundle.version,
      sourceId: resource.source.sourceId,
      sourceRevision: resource.source.revision,
      sha256: resource.digest,
      uri: resource.source.uri,
    );
  }
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'bundleVersion': bundleVersion,
    'sourceId': sourceId,
    'sourceRevision': sourceRevision,
    'sha256': sha256,
    'uri': uri.toString(),
  };
  factory PipelineAssetReference.fromJson(Map<String, Object?> value) {
    if (value['schemaVersion'] != schemaVersion || value.length != 6) {
      throw const FormatException('Unsupported asset reference schema.');
    }
    try {
      return PipelineAssetReference(
        bundleVersion: value['bundleVersion'] as String,
        sourceId: value['sourceId'] as String,
        sourceRevision: value['sourceRevision'] as String,
        sha256: value['sha256'] as String,
        uri: Uri.parse(value['uri'] as String),
      );
    } on ArgumentError {
      throw const FormatException('Invalid asset reference fields.');
    } on TypeError {
      throw const FormatException('Invalid asset reference field types.');
    }
  }
  String encode() => jsonEncode(toJson());
  factory PipelineAssetReference.decode(String source) {
    if (source.length > 16384) {
      throw const FormatException('Asset reference exceeds its size limit.');
    }
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Asset reference must be an object.');
    }
    return PipelineAssetReference.fromJson(value);
  }
}

enum PipelineAssetStatus { available, missingBundle, missingSource, mismatch }

final class PipelineAssetUnavailable implements Exception {
  final PipelineAssetStatus status;
  const PipelineAssetUnavailable(this.status);
  @override
  String toString() => 'Pipeline asset unavailable: ${status.name}.';
}

/// Resolves exact version pins through a host-authorized bundle store. Store
/// failures propagate; a denied request or corruption is never reported as missing.
final class PipelineAssetLibrary {
  final Future<PipelineBundle?> Function(
    String version,
    LoadCancellation cancellation,
  )
  readBundle;
  final AssetServices services;
  const PipelineAssetLibrary({
    required this.readBundle,
    this.services = const AssetServices(),
  });

  Future<(PipelineAssetStatus, PipelineBundle?)> _resolve(
    PipelineAssetReference reference,
    LoadCancellation token,
  ) async {
    token.throwIfCancelled();
    final bundle = await readBundle(reference.bundleVersion, token);
    token.throwIfCancelled();
    if (bundle == null) return (PipelineAssetStatus.missingBundle, null);
    if (bundle.version != reference.bundleVersion) {
      return (PipelineAssetStatus.mismatch, null);
    }
    final resources = bundle.resources.where(
      (r) => r.source.sourceId == reference.sourceId,
    );
    if (resources.isEmpty) return (PipelineAssetStatus.missingSource, null);
    final resource = resources.single;
    if (resource.digest != reference.sha256 ||
        resource.source.revision != reference.sourceRevision ||
        resource.source.uri != reference.uri) {
      return (PipelineAssetStatus.mismatch, null);
    }
    return (PipelineAssetStatus.available, bundle);
  }

  Future<PipelineAssetStatus> inspect(
    PipelineAssetReference reference, {
    LoadCancellation? cancellation,
  }) async =>
      (await _resolve(reference, cancellation ?? PipelineCancellation())).$1;

  Future<PipelineLoadedAsset> loadGltf(
    PipelineAssetReference reference, {
    GltfOptions options = const GltfOptions(),
    LoadCancellation? cancellation,
  }) async {
    final token = cancellation ?? PipelineCancellation();
    final (status, bundle) = await _resolve(reference, token);
    if (bundle == null) throw PipelineAssetUnavailable(status);
    final scope = bundle.open(services: services);
    final task = scope.load(
      bundle.gltfRequest(sourceId: reference.sourceId, options: options),
    );
    final handle = token.onCancel(task.cancel);
    try {
      final model = await task.result;
      token.throwIfCancelled();
      return PipelineLoadedAsset._(reference, model, scope);
    } catch (_) {
      await scope.close();
      rethrow;
    } finally {
      handle.dispose();
    }
  }
}

/// One CPU model template and its resource scope. Instances retain their own
/// data after close; the host removes scene instances and owns replacement/undo.
final class PipelineLoadedAsset {
  final PipelineAssetReference reference;
  final ModelAsset model;
  final AssetScope _scope;
  PipelineLoadedAsset._(this.reference, this.model, this._scope);
  ModelInstance instantiate() => model.instantiate();
  Future<void> close() => _scope.close();
}
