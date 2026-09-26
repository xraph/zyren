enum IssueSeverity { info, warning, error }

/// Operational failures have stable codes; messages are for people.
class SceneIssue {
  final String code, message, operation;
  final IssueSeverity severity;
  final Object? cause;
  const SceneIssue({
    required this.code,
    required this.message,
    required this.operation,
    this.severity = IssueSeverity.error,
    this.cause,
  });
  @override
  String toString() => '$operation: $message ($code)';
}

abstract final class SceneIssueCodes {
  static const backendUnavailable = 'backendUnavailable';
  static const presentationUnavailable = 'presentationUnavailable';
  static const unsupportedFeature = 'unsupportedFeature';
  static const disposed = 'disposed';
  static const renderFailed = 'renderFailed';
}

class SceneException implements Exception {
  final SceneIssue issue;
  const SceneException(this.issue);
  @override
  String toString() => issue.toString();
}
