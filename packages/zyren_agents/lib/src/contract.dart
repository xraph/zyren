part of '../zyren_agents.dart';

const agentSchemaVersion = '1.0';
const sceneAgents = ServiceKey<AgentRegistry>('zyren.agents');

enum AgentStatus {
  ok,
  empty,
  unsupported,
  unavailable,
  denied,
  stale,
  cancelled,
  failed,
  invalid,
}

/// JSON Schema descriptions use the bounded subset in [AgentSchema].
final class AgentTool {
  final String name, description;
  final Map<String, Object?> inputSchema, outputSchema;
  final Set<String> requiredScopes;
  final bool readOnly;
  final int maxResultBytes;
  final List<Map<String, Object?>> examples;
  AgentTool({
    required this.name,
    required this.description,
    required Map<String, Object?> inputSchema,
    required Map<String, Object?> outputSchema,
    this.readOnly = true,
    Set<String> requiredScopes = const {},
    this.maxResultBytes = 65536,
    List<Map<String, Object?>> examples = const [],
  }) : inputSchema = _freezeMap(inputSchema),
       outputSchema = _freezeMap(outputSchema),
       requiredScopes = Set.unmodifiable(requiredScopes),
       examples = List.unmodifiable(examples.map(_freezeMap)) {
    _identifier(name);
    AgentSchema.check(inputSchema);
    AgentSchema.check(outputSchema);
    if (maxResultBytes < 1 || maxResultBytes > 1048576) {
      throw ArgumentError(
        'Tool result limit must be between 1 and 1048576 bytes.',
      );
    }
    if (!readOnly && requiredScopes.isEmpty) {
      throw ArgumentError(
        'Mutating tools must declare a host permission scope.',
      );
    }
  }
  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
    'outputSchema': outputSchema,
    'readOnly': readOnly,
    'requiredScopes': requiredScopes.toList()..sort(),
    'maxResultBytes': maxResultBytes,
    'examples': examples,
    'annotations': {
      'readOnlyHint': readOnly,
      'destructiveHint': !readOnly,
      'idempotentHint': readOnly,
      'openWorldHint': false,
    },
  };
}

/// Providers live for one attached instance. IDs use letters, digits, dots,
/// underscores and hyphens. Read-only calls must not change [revision].
abstract class AgentProvider {
  String get id;
  String get version;
  String get instanceId;
  int get revision;
  List<AgentTool> get tools;
  Map<String, Object?> get capabilities => const {};
  List<Map<String, Object?>> get resources => const [];
  FutureOr<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  );
}

final class AgentResult {
  final AgentStatus status;
  final Map<String, Object?> data;
  final String? message;
  final int? revision;
  final List<String> affectedIds;
  AgentResult(
    this.status, {
    Map<String, Object?> data = const {},
    this.message,
    this.revision,
    List<String> affectedIds = const [],
  }) : data = _freezeMap(data),
       affectedIds = List.unmodifiable(affectedIds);
  bool get isSuccess => status == AgentStatus.ok || status == AgentStatus.empty;
  Map<String, Object?> toJson() => {
    'schemaVersion': agentSchemaVersion,
    'status': status.name,
    'data': data,
    if (message != null) 'message': message,
    if (revision != null) 'revision': revision,
    'affectedIds': affectedIds,
  };
}

/// Cancellation is cooperative. Providers must check before a command commits
/// and at bounded intervals during jobs. It cannot undo an already committed action.
final class AgentCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const AgentCancelledException();
  }
}

final class AgentCancelledException implements Exception {
  const AgentCancelledException();
}

final class AgentCallContext {
  final AgentCancellation cancellation;
  final int? expectedRevision;
  final String? idempotencyKey;
  final void Function(double fraction, String message)? onProgress;
  AgentCallContext._(
    this.cancellation,
    this.expectedRevision,
    this.idempotencyKey,
    this.onProgress,
  );
  void checkCancelled() => cancellation.throwIfCancelled();
  void reportProgress(double fraction, String message) {
    checkCancelled();
    if (!fraction.isFinite ||
        fraction < 0 ||
        fraction > 1 ||
        message.length > 1024) {
      throw ArgumentError('Invalid progress update.');
    }
    onProgress?.call(fraction, message);
  }
}

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    _freeze(jsonDecode(jsonEncode(value))) as Map<String, Object?>;
Object? _freeze(Object? value) {
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freeze(value))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

void _identifier(String id) {
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,95}$').hasMatch(id)) {
    throw ArgumentError.value(id, 'identifier');
  }
}
