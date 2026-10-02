import 'model.dart';

/// One conditional field replacement. Reuse the same ID and bytes on retry.
final class SceneOperation {
  static const schemaVersion = 1;
  static const maxCharacters = 4096;
  final String sceneId, epoch, operationId;
  final SceneObjectId objectId;
  final int expectedRevision;
  final SceneField field;
  final SceneTransform? transform;
  final bool? visible;

  SceneOperation({
    required this.sceneId,
    required this.epoch,
    required this.operationId,
    required this.objectId,
    required this.expectedRevision,
    required this.field,
    this.transform,
    this.visible,
  }) {
    checkText(sceneId, 'sceneId');
    checkText(epoch, 'epoch');
    checkText(operationId, 'operationId');
    checkRevision(expectedRevision);
    if (field == SceneField.transform
        ? transform == null || visible != null
        : visible == null || transform != null) {
      throw ArgumentError('An operation replaces exactly one typed field.');
    }
  }

  String encode() => boundedEncode({
    'schemaVersion': schemaVersion,
    'sceneId': sceneId,
    'epoch': epoch,
    'operationId': operationId,
    'objectId': objectId.toJson(),
    'expectedRevision': expectedRevision,
    'field': field.name,
    'value': field == SceneField.transform ? transform!.toJson() : visible,
  }, maxCharacters);

  factory SceneOperation.decode(String source) => decodeChecked(() {
    final json = boundedDecode(source, maxCharacters);
    if (json['schemaVersion'] != schemaVersion ||
        !SceneField.values.any((field) => field.name == json['field'])) {
      throw const FormatException('Unsupported scene operation schema.');
    }
    final field = SceneField.values.byName(json['field'] as String);
    if (field == SceneField.visibility && json['value'] is! bool) {
      throw const FormatException('Expected visibility boolean.');
    }
    return SceneOperation(
      sceneId: textValue(json['sceneId']),
      epoch: textValue(json['epoch']),
      operationId: textValue(json['operationId']),
      objectId: SceneObjectId.fromJson(json['objectId']),
      expectedRevision: revisionValue(json['expectedRevision']),
      field: field,
      transform: field == SceneField.transform
          ? SceneTransform.fromJson(json['value'])
          : null,
      visible: field == SceneField.visibility ? json['value'] as bool : null,
    );
  });

  /// A new decision against the exact field revision shown in a conflict.
  SceneOperation retryAgainst({
    required String newOperationId,
    required int revision,
  }) => SceneOperation(
    sceneId: sceneId,
    epoch: epoch,
    operationId: newOperationId,
    objectId: objectId,
    expectedRevision: revision,
    field: field,
    transform: transform,
    visible: visible,
  );
}

sealed class SceneOperationResult {
  final SceneOperation operation;
  final SceneSnapshot snapshot;
  const SceneOperationResult(this.operation, this.snapshot);
}

final class SceneOperationAccepted extends SceneOperationResult {
  /// Revision of this operation, even when a retry returns a newer snapshot.
  final int committedRevision;
  final bool duplicate;
  const SceneOperationAccepted({
    required SceneOperation operation,
    required SceneSnapshot snapshot,
    required this.committedRevision,
    this.duplicate = false,
  }) : super(operation, snapshot);
}

final class SceneOperationConflict extends SceneOperationResult {
  const SceneOperationConflict({
    required SceneOperation operation,
    required SceneSnapshot snapshot,
  }) : super(operation, snapshot);
  SceneObjectState get current => snapshot.objects[operation.objectId]!;
  int get actualRevision => current.revisionFor(operation.field);
}

/// The host authenticates the connection and owns its lifetime and credentials.
/// Implementations must atomically authorize, compare, commit and retain receipts.
abstract interface class SceneOperationTransport {
  Future<SceneSnapshot> read();
  Future<SceneOperationResult> submit(SceneOperation operation);
}

final class SceneAccessDenied implements Exception {
  const SceneAccessDenied();
  @override
  String toString() => 'Scene access denied.';
}

final class SceneSessionMismatch implements Exception {
  const SceneSessionMismatch();
  @override
  String toString() =>
      'Scene identity or epoch changed. Reconciliation required.';
}

final class SceneReceiptCapacityExceeded implements Exception {
  const SceneReceiptCapacityExceeded();
  @override
  String toString() => 'Scene receipt capacity reached. No edit was committed.';
}

/// Accepted edits contain source data, never transport credentials.
final class SceneOperationRecord {
  final SceneOperation operation;
  final int revision;
  const SceneOperationRecord(this.operation, this.revision);
}

final class SceneHistoryPage {
  final int sceneRevision;
  final List<SceneOperationRecord> records;
  final int? nextAfterRevision;
  SceneHistoryPage({
    required this.sceneRevision,
    required Iterable<SceneOperationRecord> records,
    this.nextAfterRevision,
  }) : records = List.unmodifiable(records);
}

/// Optional authority queries. Permission previews never replace commit checks.
abstract interface class SceneCollaborationQueries {
  Future<SceneHistoryPage> history({
    required int expectedRevision,
    int afterRevision = 0,
    int limit = 50,
  });
  Future<bool> allows(SceneOperation operation);
}

final class SceneRevisionMismatch implements Exception {
  const SceneRevisionMismatch();
  @override
  String toString() => 'Scene revision changed. Refresh the query.';
}

/// Optional in-process precommit guard for cancellation and scene target checks.
/// Network adapters need an equivalent server-side cancellation contract.
abstract interface class GuardedSceneOperationTransport {
  Future<SceneOperationResult> submitGuarded(
    SceneOperation operation, {
    required void Function() checkBeforeCommit,
  });
}
