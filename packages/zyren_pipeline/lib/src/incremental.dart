import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'bundle.dart';

/// One pure, versioned preparation step. Update [toolVersion] whenever its
/// implementation or native encoder changes. Every input dependency is explicit.
final class PipelineTransform {
  final String sourceId, tool, toolVersion;
  final Uri uri;
  final String? mediaType;
  final List<String> inputs;
  final Map<String, Object?> options;
  final Future<Uint8List> Function(PipelineTransformContext context) run;
  PipelineTransform({
    required this.sourceId,
    required this.uri,
    required this.tool,
    required this.toolVersion,
    required List<String> inputs,
    required this.run,
    Map<String, Object?> options = const {},
    this.mediaType,
  }) : inputs = List.unmodifiable(inputs),
       options =
           _freeze(jsonDecode(jsonEncode(_canonical(options))))
               as Map<String, Object?> {
    PipelineSource(sourceId: sourceId, revision: toolVersion, uri: uri);
    if (tool.isEmpty ||
        tool.length > 256 ||
        inputs.isEmpty ||
        inputs.toSet().length != inputs.length) {
      throw ArgumentError(
        'A transform needs a tool identity and distinct input IDs.',
      );
    }
  }
}

final class PipelineTransformContext {
  final Map<String, PipelineResource> inputs;
  final LoadCancellation cancellation;
  final int maxOutputBytes;
  PipelineTransformContext._(
    Map<String, PipelineResource> inputs,
    this.cancellation,
    this.maxOutputBytes,
  ) : inputs = Map.unmodifiable(inputs);
}

final class PipelineBuildResult {
  final PipelineBundle bundle;
  final List<String> built, reused;
  final Map<String, String> fingerprints;
  PipelineBuildResult._(
    this.bundle,
    Iterable<String> built,
    Iterable<String> reused,
    Map<String, String> fingerprints,
  ) : built = List.unmodifiable(built),
      reused = List.unmodifiable(reused),
      fingerprints = Map.unmodifiable(fingerprints);

  /// Restore reuse evidence from an integrity-checked bundle. The caller decides
  /// whether its publisher is trusted; a content hash is not a signature.
  factory PipelineBuildResult.restore(PipelineBundle bundle) {
    final receipt = bundle.resource(_receiptId);
    final json = jsonDecode(utf8.decode(receipt.bytes));
    if (json is! Map ||
        json['schemaVersion'] != 1 ||
        json['transforms'] is! List ||
        (json['transforms'] as List).length > bundle.resources.length) {
      throw const FormatException('Invalid pipeline build receipt.');
    }
    final fingerprints = <String, String>{};
    for (final row in json['transforms'] as List) {
      if (row is! Map ||
          row['sourceId'] is! String ||
          row['fingerprint'] is! String) {
        throw const FormatException('Invalid transform receipt.');
      }
      final id = row['sourceId'] as String;
      final resource = bundle.resource(id);
      if (fingerprints.containsKey(id) ||
          resource.digest != row['outputSha256'] ||
          resource.source.revision != row['fingerprint']) {
        throw const FormatException(
          'Transform receipt does not match its output.',
        );
      }
      fingerprints[id] = row['fingerprint'] as String;
    }
    return PipelineBuildResult._(bundle, const [], const [], fingerprints);
  }
}

/// Re-reads source bytes on each build. Only unchanged pure transform outputs are
/// reused, with input digests, revisions, locations, options and tool pins in the key.
final class PipelineIncrementalBuilder {
  final PipelineBuilder sourceBuilder;
  const PipelineIncrementalBuilder(this.sourceBuilder);

  Future<PipelineBuildResult> build({
    required List<PipelineSource> sources,
    required List<PipelineTransform> transforms,
    required String entrySourceId,
    PipelineBuildResult? previous,
    LoadCancellation? cancellation,
  }) async {
    final token = cancellation ?? PipelineCancellation();
    token.throwIfCancelled();
    if (sources.length + transforms.length + 1 >
        sourceBuilder.limits.maxSources) {
      throw const FormatException('Build graph exceeds the source budget.');
    }
    final steps = {for (final step in transforms) step.sourceId: step};
    final sourceIds = sources.map((s) => s.sourceId).toSet();
    if (sources.isEmpty ||
        sourceIds.length != sources.length ||
        steps.length != transforms.length ||
        sourceIds.contains(_receiptId) ||
        steps.containsKey(_receiptId) ||
        sourceIds.any(steps.containsKey) ||
        (!sourceIds.contains(entrySourceId) &&
            !steps.containsKey(entrySourceId))) {
      throw ArgumentError(
        'Build IDs must be unique and include the entry source.',
      );
    }
    final allUris = [
      ...sources.map((s) => s.uri),
      ...transforms.map((s) => s.uri),
    ];
    if (allUris.toSet().length != allUris.length ||
        allUris.contains(Uri.parse('pipeline:///build-receipt.json'))) {
      throw ArgumentError(
        'Build resource URIs must be unique and not reserved.',
      );
    }
    final order = <PipelineTransform>[], active = <String>{}, done = <String>{};
    void visit(String id) {
      if (sourceIds.contains(id) || done.contains(id)) return;
      if (!steps.containsKey(id)) {
        throw ArgumentError('Missing build dependency $id.');
      }
      if (!active.add(id)) {
        throw ArgumentError('Build dependency cycle at $id.');
      }
      for (final dependency in steps[id]!.inputs) {
        visit(dependency);
      }
      active.remove(id);
      done.add(id);
      order.add(steps[id]!);
    }

    for (final id in steps.keys.toList()..sort()) {
      visit(id);
    }
    final sourceBundle = await sourceBuilder.build(
      entrySourceId: sources.first.sourceId,
      sources: sources,
      cancellation: token,
    );
    final resources = {
      for (final r in sourceBundle.resources) r.source.sourceId: r,
    };
    final built = <String>[],
        reused = <String>[],
        fingerprints = <String, String>{};
    final receipts = <Map<String, Object?>>[];
    var total = sourceBundle.byteLength;
    for (final step in order) {
      token.throwIfCancelled();
      final inputIds = step.inputs.toList()..sort();
      final recipe = <String, Object?>{
        'tool': step.tool,
        'toolVersion': step.toolVersion,
        'options': step.options,
        'sourceId': step.sourceId,
        'uri': step.uri.toString(),
        'mediaType': step.mediaType,
        'inputs': [
          for (final id in inputIds)
            {
              'sourceId': id,
              'revision': resources[id]!.source.revision,
              'uri': resources[id]!.source.uri.toString(),
              'effectiveUri': resources[id]!.effectiveUri.toString(),
              'sha256': resources[id]!.digest,
              'mediaType': resources[id]!.mediaType,
            },
        ],
      };
      final fingerprint = sha256
          .convert(utf8.encode(jsonEncode(_canonical(recipe))))
          .toString();
      final remaining = sourceBuilder.limits.maxTotalBytes - total;
      final maxOutput = remaining < sourceBuilder.limits.maxSourceBytes
          ? remaining
          : sourceBuilder.limits.maxSourceBytes;
      if (maxOutput <= 0) {
        throw const FormatException('Build payload budget exceeded.');
      }
      Uint8List bytes;
      if (previous?.fingerprints[step.sourceId] == fingerprint) {
        bytes = previous!.bundle.resource(step.sourceId).bytes;
        reused.add(step.sourceId);
      } else {
        bytes = await step.run(
          PipelineTransformContext._(
            {for (final id in inputIds) id: resources[id]!},
            token,
            maxOutput,
          ),
        );
        built.add(step.sourceId);
      }
      token.throwIfCancelled();
      if (bytes.length > maxOutput) {
        throw const FormatException('Transform output exceeds its budget.');
      }
      // Use the existing builder to freeze bytes and enforce normal URI policy.
      final derived =
          await PipelineBuilder(
            resolver: _PreparedSources({
              step.uri: ResolvedSource(
                effectiveUri: step.uri,
                bytes: bytes,
                mediaType: step.mediaType,
              ),
            }),
            limits: sourceBuilder.limits,
            policy: sourceBuilder.policy,
          ).build(
            entrySourceId: step.sourceId,
            sources: [
              PipelineSource(
                sourceId: step.sourceId,
                revision: fingerprint,
                uri: step.uri,
              ),
            ],
            cancellation: token,
          );
      final output = derived.resource(step.sourceId);
      resources[step.sourceId] = output;
      total += output.bytes.length;
      fingerprints[step.sourceId] = fingerprint;
      receipts.add({
        ...recipe,
        'fingerprint': fingerprint,
        'outputSha256': output.digest,
      });
    }
    final receiptBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(_canonical({'schemaVersion': 1, 'transforms': receipts})),
      ),
    );
    final receiptSource = PipelineSource(
      sourceId: _receiptId,
      revision: sha256.convert(receiptBytes).toString(),
      uri: Uri.parse('pipeline:///build-receipt.json'),
    );
    final resolver = _PreparedSources({
      for (final r in resources.values)
        r.source.uri: ResolvedSource(
          effectiveUri: r.effectiveUri,
          bytes: r.bytes,
          mediaType: r.mediaType,
        ),
      receiptSource.uri: ResolvedSource(
        effectiveUri: receiptSource.uri,
        bytes: receiptBytes,
        mediaType: 'application/json',
      ),
    });
    final bundle =
        await PipelineBuilder(
          resolver: resolver,
          limits: sourceBuilder.limits,
          policy: sourceBuilder.policy,
        ).build(
          entrySourceId: entrySourceId,
          sources: [...resources.values.map((r) => r.source), receiptSource],
          processing: PipelineProcessing.derived,
          cancellation: token,
        );
    return PipelineBuildResult._(bundle, built, reused, fingerprints);
  }
}

/// Cooperative cancellation for build, file and native preparation jobs.
final class PipelineCancellation implements LoadCancellation {
  bool _cancelled = false;
  final _callbacks = <void Function()>{};
  @override
  bool get isCancelled => _cancelled;
  @override
  void throwIfCancelled() {
    if (_cancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
    return Registration(() => _callbacks.remove(callback));
  }

  List<Object> cancel() {
    if (_cancelled) return const [];
    _cancelled = true;
    final errors = <Object>[];
    for (final callback in List.of(_callbacks)) {
      try {
        callback();
      } catch (error) {
        errors.add(error);
      }
    }
    _callbacks.clear();
    return errors;
  }
}

Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freeze(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

const _receiptId = '_pipeline.build-receipt';
Object? _canonical(Object? value) {
  if (value is Map) {
    return {
      for (final key in value.keys.cast<String>().toList()..sort())
        key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

final class _PreparedSources implements ByteSourceResolver {
  final Map<Uri, ResolvedSource> sources;
  _PreparedSources(this.sources);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    final value = sources[uri]!;
    context.reportProgress(value.bytes.length, value.bytes.length);
    return value;
  }
}
