part of '../agents.dart';

final class _AgentJobs {
  final AgentRegistry registry;
  final _jobs = <String, _AgentJob>{};
  final _events = <Map<String, Object?>>[];
  late final StreamSubscription<Map<String, Object?>> _subscription;
  int _cursor = 0;
  bool _disposed = false;
  _AgentJobs(this.registry) {
    _subscription = registry.changes.listen(_record);
  }
  static const _jobId = {'type': 'string', 'minLength': 1, 'maxLength': 96};
  static const _jobInput = {
    'type': 'object',
    'properties': {'jobId': _jobId},
    'required': ['jobId'],
    'additionalProperties': false,
  };
  static const _read = {
    'readOnlyHint': true,
    'destructiveHint': false,
    'idempotentHint': true,
    'openWorldHint': false,
  };
  static const _write = {
    'readOnlyHint': false,
    'destructiveHint': true,
    'idempotentHint': false,
    'openWorldHint': false,
  };
  static const tools = <Map<String, Object?>>[
    {
      'name': 'agent_job_start',
      'description':
          'Start bounded cooperative provider work. Reuse jobId for an exact retry; inspect progress through status. At most 16 retained jobs.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          ...AgentDevtoolsBridge._callProperties,
          'jobId': _jobId,
          'readOnly': {'type': 'boolean'},
        },
        'required': ['jobId', 'providerId', 'instanceId', 'tool', 'readOnly'],
        'additionalProperties': false,
      },
      'annotations': _write,
    },
    {
      'name': 'agent_job_status',
      'description': 'Read one job, its latest progress and bounded result.',
      'inputSchema': _jobInput,
      'annotations': _read,
    },
    {
      'name': 'agent_job_cancel',
      'description':
          'Request cooperative cancellation. This cannot undo an action already committed.',
      'inputSchema': _jobInput,
      'annotations': _write,
    },
    {
      'name': 'agent_job_release',
      'description':
          'Release a completed result. Running jobs must finish or acknowledge cancellation first.',
      'inputSchema': _jobInput,
      'annotations': _write,
    },
    {
      'name': 'agent_changes',
      'description':
          'Read bounded registration, command and job changes after a cursor. A gap requires refreshing discovery and state.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'after': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 64},
        },
        'additionalProperties': false,
      },
      'annotations': _read,
    },
  ];
  static bool accepts(String name) => tools.any((tool) => tool['name'] == name);
  void _record(Map<String, Object?> event) {
    if (_disposed) return;
    _events.add({...event, 'cursor': ++_cursor});
    if (_events.length > 128) _events.removeAt(0);
  }

  Map<String, Object?> _envelope(Map<String, Object?> data) => {
    'schemaVersion': SceneDiagnostics.schemaVersion,
    ...data,
  };
  Map<String, Object?> call(String name, Map<String, Object?> arguments) {
    if (_disposed) {
      throw const DiagnosticException('unavailable', 'Job bridge is closed.');
    }
    if (name == 'agent_changes') {
      final after = arguments['after'] as int? ?? 0,
          limit = arguments['limit'] as int? ?? 32;
      final events = _events
          .where((e) => (e['cursor'] as int) > after)
          .take(limit)
          .toList();
      return _envelope({
        'agentChanges': {
          'events': events,
          'nextCursor': events.isEmpty ? _cursor : events.last['cursor'],
          'gap':
              after > _cursor ||
              (_events.isNotEmpty &&
                  after < (_events.first['cursor'] as int) - 1),
        },
      });
    }
    final id = arguments['jobId'] as String;
    var job = _jobs[id];
    if (name == 'agent_job_start') {
      // JSON freezing prevents a direct caller from mutating an in-flight request.
      final encoded = jsonEncode(arguments);
      if (utf8.encode(encoded).length > 16384) {
        throw const DiagnosticException(
          'payloadTooLarge',
          'Job arguments exceed 16 KiB.',
        );
      }
      final frozen = jsonDecode(encoded) as Map<String, dynamic>;
      final fingerprint = jsonEncode(_canonicalJob(frozen));
      if (job != null && job.fingerprint != fingerprint) {
        throw const DiagnosticException(
          'invalidArguments',
          'Job ID belongs to different arguments.',
        );
      }
      if (job == null) {
        if (_jobs.length >= 16) {
          throw const DiagnosticException(
            'unavailable',
            'Release a completed job before starting another.',
          );
        }
        job = _AgentJob(id, fingerprint);
        _jobs[id] = job;
        _record({'kind': 'job-started', 'jobId': id});
        unawaited(_run(job, frozen));
      }
    } else if (job == null) {
      throw const DiagnosticException(
        'unavailable',
        'Job is absent or released.',
      );
    } else if (name == 'agent_job_cancel') {
      if (job.result == null) {
        job.cancellation.cancel();
        _record({'kind': 'job-cancel-requested', 'jobId': id});
      }
    } else if (name == 'agent_job_release') {
      if (job.result == null) {
        throw const DiagnosticException('unavailable', 'Job has not finished.');
      }
      _jobs.remove(id);
      return _envelope({'releasedJobId': id});
    }
    return _envelope({'agentJob': job.toJson()});
  }

  Future<void> _run(_AgentJob job, Map<String, Object?> arguments) async {
    final timer = Timer(const Duration(minutes: 5), () {
      job.cancellation.cancel();
      _record({'kind': 'job-timeout', 'jobId': job.id});
    });
    job.timer = timer;
    try {
      job.result = await registry.call(
        providerId: arguments['providerId'] as String,
        instanceId: arguments['instanceId'] as String,
        tool: arguments['tool'] as String,
        arguments:
            (arguments['arguments'] as Map<String, Object?>?) ?? const {},
        expectedRevision: arguments['expectedRevision'] as int?,
        idempotencyKey: arguments['idempotencyKey'] as String?,
        readOnlyOnly: arguments['readOnly'] as bool,
        cancellation: job.cancellation,
        onProgress: (fraction, message) {
          job.progress = {'fraction': fraction, 'message': message};
          _record({'kind': 'job-progress', 'jobId': job.id, ...job.progress!});
        },
      );
      _record({
        'kind': 'job-completed',
        'jobId': job.id,
        'status': job.result!.status.name,
      });
    } catch (_) {
      job.result = AgentResult(
        AgentStatus.failed,
        message: 'Job execution failed.',
      );
      _record({'kind': 'job-completed', 'jobId': job.id, 'status': 'failed'});
    } finally {
      timer.cancel();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in _jobs.values) {
      job.cancellation.cancel();
      job.timer?.cancel();
    }
    _jobs.clear();
    _events.clear();
    unawaited(_subscription.cancel());
  }
}

final class _AgentJob {
  final String id, fingerprint;
  final cancellation = AgentCancellation();
  AgentResult? result;
  Map<String, Object?>? progress;
  Timer? timer;
  _AgentJob(this.id, this.fingerprint);
  Map<String, Object?> toJson() => {
    'id': id,
    'state': result == null ? 'running' : 'complete',
    'cancelRequested': cancellation.isCancelled,
    'progress': progress,
    'result': result?.toJson(),
  };
}

Object? _canonicalJob(Object? value) {
  if (value is Map<String, Object?>) {
    return {
      for (final key in value.keys.toList()..sort())
        key: _canonicalJob(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalJob).toList();
  return value;
}
