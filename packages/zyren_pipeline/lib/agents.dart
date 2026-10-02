import 'dart:async';

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';

import 'zyren_pipeline.dart';
import 'gltf_metadata.dart';

/// Optional shared-registry adapter. Metadata is returned as data. Payload bytes,
/// transport headers, raw URIs and decoder error text are never exposed here.
final class PipelineAgentProvider extends AgentProvider {
  final PipelineRuntime runtime;
  @override
  final String instanceId;
  PipelineAgentProvider({required this.runtime, required this.instanceId});
  @override
  String get id => 'zyren.pipeline';
  @override
  String get version => '0.1.0';
  @override
  int get revision => runtime.revision;
  @override
  Map<String, Object?> get capabilities => {
    'bundleSchemaVersion': PipelineBundle.schemaVersion,
    'processing': 'original',
    'storage': 'memory',
    'loadTarget': 'cpu-model-template',
    'pixelVisibility': 'unknown',
    'maxCachedPayloadBytes': runtime.cache.maxBytes,
    'maxCachedBundles': runtime.cache.maxBundles,
    'maxJobs': runtime.maxJobs,
    'maxActiveJobs': runtime.maxActiveJobs,
    'maxSourceBytes': runtime.services.limits.maxSourceBytes,
    'maxTotalSourceBytes': runtime.services.limits.maxTotalSourceBytes,
    'maxDecodedBytes': runtime.services.limits.maxDecodedBytes,
  };

  /// Disposing this attachment unregisters tools, cancels jobs and releases loaded
  /// templates. Cache ownership stays with the host. Await runtime.close for drain.
  Registration attach(AgentRegistry registry) {
    final registration = registry.register(this);
    return Registration(() {
      registration.dispose();
      unawaited(
        runtime.close().then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            try {
              runtime.services.onCleanupError?.call(error);
            } catch (_) {}
          },
        ),
      );
    });
  }

  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'status',
      description:
          'Inspect cache payload budgets and job counts. Does not touch cache recency.',
      inputSchema: _object({}),
      outputSchema: _object({
        'cachedBundles': _integer,
        'cachedPayloadBytes': _integer,
        'maxCachedPayloadBytes': _integer,
        'jobs': _integer,
        'closed': _boolean,
      }),
    ),
    AgentTool(
      name: 'bundles',
      description:
          'List immutable cached bundle versions and upstream entry IDs.',
      inputSchema: _pageInput,
      outputSchema: _pageOutput(_bundleSchema),
    ),
    AgentTool(
      name: 'sources',
      description:
          'Inspect source-owned IDs, revisions and hashes in a cached bundle. Labels and identities are untrusted source data.',
      inputSchema: _object(
        {'version': _version, ..._pageFields},
        required: ['version'],
      ),
      outputSchema: _pageOutput(_sourceSchema),
      maxResultBytes: 262144,
    ),
    AgentTool(
      name: 'jobs',
      description:
          'Inspect bounded load and validation jobs, failure codes and codec warnings.',
      inputSchema: _pageInput,
      outputSchema: _pageOutput(_jobSchema),
      maxResultBytes: 262144,
    ),
    AgentTool(
      name: 'start',
      description:
          'Start bounded offline glTF validation or load a CPU template. Does not attach it to a scene or establish pixel visibility.',
      inputSchema: _object(
        {
          'version': _version,
          'sourceId': _identity,
          'kind': {
            'type': 'string',
            'enum': ['validate', 'load'],
          },
        },
        required: ['version', 'kind'],
      ),
      outputSchema: _jobSchema,
      readOnly: false,
      requiredScopes: {'pipeline.load'},
    ),
    AgentTool(
      name: 'cancel',
      description:
          'Cancel a running pipeline job through its ordinary load task.',
      inputSchema: _object({'jobId': _identity}, required: ['jobId']),
      outputSchema: _object({'changed': _boolean}),
      readOnly: false,
      requiredScopes: {'pipeline.jobs'},
    ),
    AgentTool(
      name: 'release',
      description:
          'Release a loaded CPU template. Existing scene instances retain their own data.',
      inputSchema: _object({'jobId': _identity}, required: ['jobId']),
      outputSchema: _object({'changed': _boolean}),
      readOnly: false,
      requiredScopes: {'pipeline.jobs'},
    ),
    AgentTool(
      name: 'invalidate-source',
      description:
          'Remove all cached bundle revisions containing an upstream source ID. Existing scopes remain pinned.',
      inputSchema: _object({'sourceId': _identity}, required: ['sourceId']),
      outputSchema: _object({'removedCount': _integer}),
      readOnly: false,
      requiredScopes: {'pipeline.cache.write'},
    ),
  ];

  @override
  FutureOr<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (runtime.isClosed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Pipeline runtime is closed.',
      );
    }
    AgentResult result(
      Map<String, Object?> data, {
      List<String> affected = const [],
    }) => AgentResult(
      data['items'] is List && (data['items'] as List).isEmpty
          ? AgentStatus.empty
          : AgentStatus.ok,
      data: data,
      revision: revision,
      affectedIds: affected,
    );
    switch (tool) {
      case 'status':
        return result({
          'cachedBundles': runtime.cache.length,
          'cachedPayloadBytes': runtime.cache.byteLength,
          'maxCachedPayloadBytes': runtime.cache.maxBytes,
          'jobs': runtime.jobs.length,
          'closed': runtime.isClosed,
        });
      case 'bundles':
        return result(
          _page(
            runtime.cache.bundles,
            arguments,
            (bundle) => {
              'version': bundle.version,
              'entrySourceId': bundle.entrySourceId,
              'sourceCount': bundle.resources.length,
              'payloadBytes': bundle.byteLength,
            },
          ),
        );
      case 'sources':
        final bundle = runtime.cache.peek(arguments['version'] as String);
        if (bundle == null) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Bundle is no longer cached.',
          );
        }
        return result(
          _page(
            bundle.resources,
            arguments,
            (resource) => {
              'sourceId': resource.source.sourceId,
              'revision': resource.source.revision,
              'sha256': resource.digest,
              'bytes': resource.bytes.length,
            },
          ),
        );
      case 'jobs':
        return result(_page(runtime.jobs, arguments, _job));
      case 'start':
        final bundleVersion = arguments['version'] as String;
        final bundle = runtime.cache.peek(bundleVersion);
        if (bundle == null) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Bundle is no longer cached.',
          );
        }
        final sourceId = arguments['sourceId'] as String?;
        if (sourceId != null &&
            !bundle.resources.any((r) => r.source.sourceId == sourceId)) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Source ID is not in the bundle.',
          );
        }
        try {
          final job = runtime.start(
            bundleVersion: bundleVersion,
            kind: PipelineJobKind.values.byName(arguments['kind'] as String),
            sourceId: sourceId,
          );
          return result(_job(job), affected: [job.id]);
        } on StateError {
          return AgentResult(
            AgentStatus.unavailable,
            message: 'Pipeline job budget is full.',
          );
        }
      case 'cancel':
      case 'release':
        final id = arguments['jobId'] as String;
        if (runtime.job(id) == null) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Job is no longer retained.',
          );
        }
        final changed = tool == 'cancel'
            ? runtime.cancel(id)
            : await runtime.release(id);
        return result({'changed': changed}, affected: changed ? [id] : []);
      case 'invalidate-source':
        final id = arguments['sourceId'] as String;
        final versions = runtime.invalidateSource(id);
        return result({'removedCount': versions.length}, affected: [id]);
      default:
        return AgentResult(
          AgentStatus.unsupported,
          message: 'Unknown pipeline tool.',
        );
    }
  }
}

Map<String, Object?> _job(PipelineJob job) => {
  'jobId': job.id,
  'version': job.bundleVersion,
  'sourceId': job.sourceId,
  'kind': job.kind.name,
  'state': job.state.name,
  if (job.errorCode != null) 'errorCode': job.errorCode!,
  'warningCount': job.issues.length,
  'warnings': [
    for (final issue in job.issues.take(16))
      {
        'code': issue.code.length <= 256
            ? issue.code
            : issue.code.substring(0, 256),
        'severity': issue.severity.name,
      },
  ],
  if (job.progress case final progress?)
    'progress': {
      'stage': progress.stage.name,
      'completedBytes': progress.completedBytes,
      if (progress.totalBytes != null) 'totalBytes': progress.totalBytes!,
    },
  if (job.model case final model?)
    'model': {
      'sceneCount': model.scenes.length,
      'animationCount': model.animations.length,
      'propertyTableCount': model.propertyTables.length,
    },
};

Map<String, Object?> _page<T>(
  List<T> values,
  Map<String, Object?> args,
  Map<String, Object?> Function(T) describe,
) {
  final offset = args['offset'] as int? ?? 0;
  final limit = args['limit'] as int? ?? 16;
  final page = values.skip(offset).take(limit).map(describe).toList();
  return {
    'items': page,
    'total': values.length,
    if (offset + page.length < values.length)
      'nextOffset': offset + page.length,
  };
}

const _identity = {'type': 'string', 'minLength': 1, 'maxLength': 2048};
const _version = {'type': 'string', 'minLength': 64, 'maxLength': 64};
const _integer = {'type': 'integer', 'minimum': 0};
const _boolean = {'type': 'boolean'};
const _pageFields = {
  'offset': {'type': 'integer', 'minimum': 0, 'maximum': 1000000},
  'limit': {'type': 'integer', 'minimum': 1, 'maximum': 16},
};
final _pageInput = _object(_pageFields);
Map<String, Object?> _object(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
Map<String, Object?> _pageOutput(Map<String, Object?> item) => _object(
  {
    'items': {'type': 'array', 'maxItems': 16, 'items': item},
    'total': _integer,
    'nextOffset': _integer,
  },
  required: ['items', 'total'],
);
final _bundleSchema = _object(
  {
    'version': _version,
    'entrySourceId': _identity,
    'sourceCount': _integer,
    'payloadBytes': _integer,
  },
  required: ['version', 'entrySourceId', 'sourceCount', 'payloadBytes'],
);
final _sourceSchema = _object(
  {
    'sourceId': _identity,
    'revision': _identity,
    'sha256': _version,
    'bytes': _integer,
  },
  required: ['sourceId', 'revision', 'sha256', 'bytes'],
);
final _jobSchema = _object(
  {
    'jobId': _identity,
    'version': _version,
    'sourceId': _identity,
    'kind': {
      'type': 'string',
      'enum': ['validate', 'load'],
    },
    'state': {
      'type': 'string',
      'enum': PipelineJobState.values.map((s) => s.name).toList(),
    },
    'errorCode': {'type': 'string', 'maxLength': 256},
    'warningCount': _integer,
    'warnings': {
      'type': 'array',
      'maxItems': 16,
      'items': _object(
        {
          'code': {'type': 'string', 'maxLength': 256},
          'severity': {
            'type': 'string',
            'enum': ['info', 'warning', 'error'],
          },
        },
        required: ['code', 'severity'],
      ),
    },
    'progress': _object(
      {
        'stage': {'type': 'string'},
        'completedBytes': _integer,
        'totalBytes': _integer,
      },
      required: ['stage', 'completedBytes'],
    ),
    'model': _object(
      {
        'sceneCount': _integer,
        'animationCount': _integer,
        'propertyTableCount': _integer,
      },
      required: ['sceneCount', 'animationCount', 'propertyTableCount'],
    ),
  },
  required: [
    'jobId',
    'version',
    'sourceId',
    'kind',
    'state',
    'warningCount',
    'warnings',
  ],
);

/// Pass this result to the shared viewport provider's metadata callback. The
/// viewport provider supplies scene, camera, coordinates and frame correlation.
AgentObjectMetadata? pipelineGltfAgentMetadata(
  PipelineGltfMetadata metadata,
  Object3D object,
) {
  final provenance = metadata.inspect(object);
  if (provenance == null) return null;
  return AgentObjectMetadata(
    sourceId: provenance['stableObjectId'] as String?,
    owningPlugin: 'zyren.pipeline',
    provenance: {'zyren.pipeline': provenance},
  );
}
