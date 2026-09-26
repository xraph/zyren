import 'capabilities.dart';

enum IssueSeverity { info, warning, error }

/// Operational failures have stable codes; messages are for people.
class SceneIssue {
  final String code, message, operation;
  final IssueSeverity severity;
  final Object? cause;
  final String? pluginId, resourceLabel, backend;
  final Uri? sourceUri;
  final int? shaderLine, shaderColumn;
  final Set<RenderFeature> requiredFeatures;
  final DeviceLimits? limits;
  SceneIssue({
    required this.code,
    required this.message,
    required this.operation,
    this.severity = IssueSeverity.error,
    this.cause,
    this.pluginId,
    this.resourceLabel,
    this.backend,
    this.sourceUri,
    this.shaderLine,
    this.shaderColumn,
    this.limits,
    Set<RenderFeature> requiredFeatures = const {},
  }) : requiredFeatures = Set.unmodifiable(requiredFeatures);
  @override
  String toString() => '$operation: $message ($code)';
}

abstract final class SceneIssueCodes {
  static const backendUnavailable = 'backendUnavailable';
  static const presentationUnavailable = 'presentationUnavailable';
  static const unsupportedFeature = 'unsupportedFeature';
  static const disposed = 'disposed';
  static const controllerAlreadyAttached = 'controllerAlreadyAttached';
  static const cleanupFailed = 'cleanupFailed';
  static const pluginDependencyMissing = 'pluginDependencyMissing';
  static const pluginDependencyCycle = 'pluginDependencyCycle';
  static const deviceLost = 'deviceLost';
  static const renderFailed = 'renderFailed';
}

class SceneException implements Exception {
  final SceneIssue issue;
  const SceneException(this.issue);
  @override
  String toString() => issue.toString();
}
