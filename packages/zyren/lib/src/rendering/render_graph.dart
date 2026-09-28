part of '../resources/resource_scope.dart';

/// Mutable registrations produce immutable candidates with [describe].
final class RenderGraph {
  final _passes = <PassDescriptor>[];
  final _inputs = <GpuResource<Object?>>[];
  Registration addCompute(ComputePassDescriptor pass) => _add(pass);
  Registration addRender(RenderPassDescriptor pass) => _add(pass);
  Registration _add(PassDescriptor pass) {
    _passes.add(pass);
    return Registration(() {
      _passes.remove(pass);
    });
  }

  Registration importResource(GpuResource<Object?> resource) {
    _inputs.add(resource);
    return Registration(() {
      _inputs.remove(resource);
    });
  }

  GraphDescription describe({String label = ''}) =>
      GraphDescription(label: label, passes: _passes, inputs: _inputs);
}

/// Inputs are initialized by work outside this graph before every execution.
final class GraphDescription {
  final String label;
  final List<PassDescriptor> passes;
  final List<GpuResource<Object?>> inputs;
  GraphDescription({
    this.label = '',
    required Iterable<PassDescriptor> passes,
    Iterable<GpuResource<Object?>> inputs = const [],
  }) : passes = List.unmodifiable(passes),
       inputs = List.unmodifiable(inputs);
}

enum GraphErrorCode {
  invalidDescriptor,
  duplicatePass,
  missingDependency,
  cycle,
  uninitializedRead,
  aliasConflict,
  accessMismatch,
  invalidBinding,
  unsupportedFeature,
  foreignResource,
  closedResource,
  pipelineFailed,
  deviceFailed,
  limitExceeded,
}

final class GraphException extends SceneException {
  final GraphErrorCode code;
  final String? passName;
  GraphException(
    this.code,
    String message, {
    this.passName,
    String? resourceLabel,
  }) : super(
         SceneIssue(
           code: 'graph.${code.name}',
           message: message,
           operation: 'graph',
           resourceLabel: resourceLabel ?? passName,
         ),
       );
}

final class GraphStats {
  final int passes, dispatches, drawCalls;
  const GraphStats({
    required this.passes,
    required this.dispatches,
    required this.drawCalls,
  });
}

final class GraphResourceLifetime {
  final String resourceLabel;
  final int firstPass, lastPass;
  const GraphResourceLifetime({
    required this.resourceLabel,
    required this.firstPass,
    required this.lastPass,
  });
}
