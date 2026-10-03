part of '../zyren_agents.dart';

/// Host-owned capability registry. Call arguments never supply permission scopes.
/// Completed results last for the provider registration. Retired command keys
/// remain tombstoned for this registry lifetime, so reattachment cannot replay
/// a command. A full session ledger rejects new mutations without evicting keys.
final class AgentRegistry {
  final Set<String> grantedScopes;
  final int maxProviders, maxInputBytes, maxRetryEntries;
  int _retryCount = 0;
  final _retiredRetries = <String, Set<String>>{};
  final _providers = <String, _ProviderEntry>{};
  final _changes = StreamController<Map<String, Object?>>.broadcast();
  bool _disposed = false;
  AgentRegistry({
    Set<String> grantedScopes = const {},
    this.maxProviders = 128,
    this.maxInputBytes = 65536,
    this.maxRetryEntries = 256,
  }) : grantedScopes = Set.unmodifiable(grantedScopes) {
    if (maxProviders < 1 || maxInputBytes < 1 || maxRetryEntries < 1) {
      throw ArgumentError('Registry limits must be positive.');
    }
  }
  Stream<Map<String, Object?>> get changes => _changes.stream;
  Registration register(AgentProvider provider) {
    if (_disposed) throw StateError('Agent registry has been disposed.');
    _identifier(provider.id);
    _identifier(provider.instanceId);
    final key = '${provider.id}/${provider.instanceId}';
    if (_providers.containsKey(key)) {
      throw StateError('Provider instance already registered.');
    }
    if (_providers.length >= maxProviders) {
      throw StateError('Provider budget exceeded.');
    }
    final tools = {for (final tool in provider.tools) tool.name: tool};
    if (tools.length != provider.tools.length || tools.length > 128) {
      throw ArgumentError('Provider tools must be unique and at most 128.');
    }
    final entry = _ProviderEntry(provider, tools);
    if (utf8.encode(jsonEncode(entry.describe())).length > 262144) {
      throw ArgumentError('Provider discovery exceeds 256 KiB.');
    }
    _providers[key] = entry;
    _changes.add({
      'kind': 'registered',
      'providerId': provider.id,
      'instanceId': provider.instanceId,
    });
    return entry.registration = Registration(() {
      if (!identical(_providers[key], entry)) return;
      _providers.remove(key);
      for (final cancellation in entry.pending.values) {
        cancellation.cancel();
      }
      if (entry.retries.isNotEmpty) {
        _retiredRetries
            .putIfAbsent(key, () => <String>{})
            .addAll(entry.retries.keys);
        entry.retries.clear();
      }
      if (!_disposed) {
        _changes.add({
          'kind': 'removed',
          'providerId': provider.id,
          'instanceId': provider.instanceId,
        });
      }
    });
  }

  Map<String, Object?> discover({int offset = 0, int limit = 32}) {
    if (_disposed) throw StateError('Agent registry has been disposed.');
    if (offset < 0 || limit < 1 || limit > 128) {
      throw ArgumentError('Invalid discovery page.');
    }
    final entries = _providers.values.toList();
    final page = entries
        .skip(offset)
        .take(limit)
        .map((entry) => entry.describe())
        .toList();
    return {
      'schemaVersion': agentSchemaVersion,
      'providers': page,
      'nextOffset': offset + page.length < entries.length
          ? offset + page.length
          : null,
    };
  }

  Future<AgentResult> call({
    required String providerId,
    required String instanceId,
    required String tool,
    Map<String, Object?> arguments = const {},
    int? expectedRevision,
    String? idempotencyKey,
    bool readOnlyOnly = false,
    AgentCancellation? cancellation,
    void Function(double fraction, String message)? onProgress,
  }) async {
    AgentResult reject(AgentStatus status, String message) =>
        AgentResult(status, message: message);
    if (_disposed) {
      return reject(AgentStatus.unavailable, 'Agent registry is disposed.');
    }
    final entry = _providers['$providerId/$instanceId'];
    if (entry == null) {
      return reject(
        AgentStatus.unavailable,
        'Provider instance is not registered.',
      );
    }
    final descriptor = entry.tools[tool];
    if (descriptor == null) {
      return reject(AgentStatus.unsupported, 'Tool is not supported.');
    }
    if (readOnlyOnly && !descriptor.readOnly) {
      return reject(
        AgentStatus.denied,
        'This endpoint accepts read-only tools.',
      );
    }
    Map<String, Object?> input;
    try {
      final encoded = jsonEncode(arguments);
      if (utf8.encode(encoded).length > maxInputBytes) {
        return reject(AgentStatus.invalid, 'Input byte budget exceeded.');
      }
      input = _freezeMap(arguments);
    } catch (_) {
      return reject(AgentStatus.invalid, 'Input must be JSON-compatible.');
    }
    final invalid = AgentSchema.validate(descriptor.inputSchema, input);
    if (invalid != null) return reject(AgentStatus.invalid, invalid);
    if (!grantedScopes.containsAll(descriptor.requiredScopes)) {
      return reject(
        AgentStatus.denied,
        'The host has not granted the required scopes.',
      );
    }
    final token = cancellation ?? AgentCancellation();
    if (token.isCancelled) {
      return reject(
        AgentStatus.cancelled,
        'Call was cancelled before execution.',
      );
    }
    String? fingerprint;
    if (!descriptor.readOnly) {
      if (expectedRevision == null ||
          idempotencyKey == null ||
          idempotencyKey.isEmpty ||
          idempotencyKey.length > 128) {
        return reject(
          AgentStatus.invalid,
          'Mutations require expectedRevision and a bounded idempotencyKey.',
        );
      }
      if (_retiredRetries['$providerId/$instanceId']?.contains(
            idempotencyKey,
          ) ??
          false) {
        return reject(
          AgentStatus.stale,
          'This command key belongs to an earlier registration. Refresh state before issuing a new command.',
        );
      }
      fingerprint = jsonEncode([tool, expectedRevision, _canonical(input)]);
      final retry = entry.retries[idempotencyKey];
      if (retry != null) {
        if (retry.$1 != fingerprint) {
          return reject(
            AgentStatus.invalid,
            'Idempotency key was used for a different command.',
          );
        }
        return retry.$2;
      }
      if (_retryCount >= maxRetryEntries) {
        return reject(
          AgentStatus.unavailable,
          'Mutation retry ledger is full.',
        );
      }
      if (entry.mutating) {
        return reject(
          AgentStatus.unavailable,
          'Another mutation is running for this instance.',
        );
      }
    }
    int before;
    try {
      before = entry.provider.revision;
    } catch (_) {
      return reject(
        AgentStatus.unavailable,
        'Provider revision is unavailable.',
      );
    }
    if (expectedRevision != null && expectedRevision != before) {
      return reject(AgentStatus.stale, 'Provider revision changed.');
    }
    if (entry.pending.length >= 32) {
      return reject(AgentStatus.unavailable, 'Provider call budget exceeded.');
    }
    final completer = Completer<AgentResult>();
    if (!descriptor.readOnly) {
      entry.mutating = true;
      entry.retries[idempotencyKey!] = (fingerprint!, completer.future);
      _retryCount++;
    }
    final pendingId = Object();
    entry.pending[pendingId] = token;
    Future<void> execute() async {
      try {
        var result = await entry.provider.invoke(
          tool,
          input,
          AgentCallContext._(
            token,
            expectedRevision,
            idempotencyKey,
            onProgress,
          ),
        );
        if (!identical(_providers['$providerId/$instanceId'], entry)) {
          result = reject(
            AgentStatus.unavailable,
            'Provider detached during the call.',
          );
        } else if (descriptor.readOnly && token.isCancelled) {
          result = reject(AgentStatus.cancelled, 'Query was cancelled.');
        } else if (descriptor.readOnly && entry.provider.revision != before) {
          result = reject(AgentStatus.stale, 'State changed during the query.');
        } else if (result.isSuccess) {
          final error = AgentSchema.validate(
            descriptor.outputSchema,
            result.data,
          );
          if (error != null) {
            result = reject(
              AgentStatus.failed,
              'Provider output violates its schema: $error',
            );
          } else if (!descriptor.readOnly &&
              result.revision != entry.provider.revision) {
            result = reject(
              AgentStatus.failed,
              'Mutation must report its resulting provider revision.',
            );
          }
        }
        if (utf8.encode(jsonEncode(result.toJson())).length >
            descriptor.maxResultBytes) {
          result = reject(
            AgentStatus.failed,
            'Tool result byte budget exceeded.',
          );
        }
        completer.complete(result);
        if (!_disposed) {
          _changes.add({
            'kind': 'call',
            'providerId': providerId,
            'instanceId': instanceId,
            'tool': tool,
            'status': result.status.name,
            'revision': result.revision,
          });
        }
      } on AgentCancelledException {
        completer.complete(
          reject(AgentStatus.cancelled, 'Provider cancelled the operation.'),
        );
      } catch (_) {
        // Provider errors may contain imported/private data. Hosts can diagnose
        // internally; transport receives a bounded error without exception text.
        completer.complete(
          reject(AgentStatus.failed, 'Provider execution failed.'),
        );
      } finally {
        entry.pending.remove(pendingId);
        if (!descriptor.readOnly) entry.mutating = false;
      }
    }

    unawaited(execute());
    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _providers.values.toList()) {
      entry.registration.dispose();
    }
    _retiredRetries.clear();
    unawaited(_changes.close());
  }
}

final class _ProviderEntry {
  final AgentProvider provider;
  final Map<String, AgentTool> tools;
  final Map<Object, AgentCancellation> pending = {};
  final retries = <String, (String, Future<AgentResult>)>{};
  late final Registration registration;
  bool mutating = false;
  _ProviderEntry(this.provider, this.tools);
  Map<String, Object?> describe() => {
    'providerId': provider.id,
    'version': provider.version,
    'instanceId': provider.instanceId,
    'revision': provider.revision,
    'capabilities': _freezeMap(provider.capabilities),
    'resources': provider.resources.map(_freezeMap).toList(),
    'tools': tools.values.map((tool) => tool.toJson()).toList(),
  };
}

Object? _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    return {
      for (final key in value.keys.toList()..sort())
        key: _canonical(value[key]),
    };
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

/// Small shared harness which exercises the registered interface for any owner.
abstract final class AgentConformance {
  static Future<List<String>> checkRead({
    required AgentRegistry registry,
    required AgentProvider provider,
    required String tool,
    Map<String, Object?> arguments = const {},
  }) async {
    final before = provider.revision;
    final result = await registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: tool,
      arguments: arguments,
      expectedRevision: before,
    );
    return [
      if (!result.isSuccess)
        'Read returned ${result.status.name}: ${result.message}',
      if (provider.revision != before) 'Read mutated provider state.',
      if (result.revision != null && result.revision != before)
        'Read reported another revision.',
    ];
  }
}
