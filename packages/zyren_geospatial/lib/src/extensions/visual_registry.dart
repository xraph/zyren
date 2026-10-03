import 'package:zyren/zyren.dart';
import '../layers/document.dart';

enum GeoVisualStage { beforeScene, afterScene, effect }

enum GeoVisualAlpha { opaque, premultiplied }

enum GeoVisualLifetime { frame, attachment }

/// Material/domain styling, separate from display conversion and image effects.
final class GeoVisualStyle {
  final String id, owner;
  final int version;
  final Map<String, Object?> configuration;
  GeoVisualStyle({
    required this.id,
    required this.owner,
    required this.version,
    required Map<String, Object?> configuration,
  }) : configuration = copyLayerDocument(configuration) {
    if (id.trim().isEmpty || owner.trim().isEmpty || version < 1) {
      throw ArgumentError(
        'Styles need an ID, owner and positive schema version.',
      );
    }
  }
}

/// Shared-graph contribution contract. Shader values use linear colour.
final class GeoVisualPass {
  final String name, owner;
  final Set<String> after, exclusive;
  final Set<RenderFeature> requirements;
  final GeoVisualStage stage;
  final GeoVisualAlpha alpha;
  final GeoVisualLifetime lifetime;
  final DepthStrategy? depthStrategy;
  GeoVisualPass({
    required this.name,
    required this.owner,
    Set<String> after = const {},
    Set<String> exclusive = const {},
    Set<RenderFeature> requirements = const {},
    this.stage = GeoVisualStage.effect,
    this.alpha = GeoVisualAlpha.premultiplied,
    this.lifetime = GeoVisualLifetime.frame,
    this.depthStrategy,
  }) : after = Set.unmodifiable(after),
       exclusive = Set.unmodifiable(exclusive),
       requirements = Set.unmodifiable(requirements) {
    if (name.trim().isEmpty ||
        owner.trim().isEmpty ||
        [...after, ...exclusive].any((v) => v.trim().isEmpty)) {
      throw ArgumentError(
        'Visual pass IDs, owners and dependency names cannot be empty.',
      );
    }
  }
}

/// Owns declarations and their actual registrations in Zyren's shared graph.
final class GeoVisualRegistration extends Registration {
  final GraphRegistration _graph;
  GeoVisualRegistration._(this._graph, void Function() release)
    : super(release);
  bool get enabled => _graph.enabled;
  set enabled(bool value) => _graph.enabled = value;
  void invalidate() => _graph.invalidate();
}

final class GeoVisualRegistry {
  final _styles = <(String, int), GeoVisualStyle>{};
  final _passes = <String, GeoVisualPass>{};
  List<GeoVisualPass> get passes => List.unmodifiable(_passes.values);
  GeoVisualStyle? style(String id, int version) => _styles[(id, version)];
  Registration registerStyle(GeoVisualStyle style) {
    final key = (style.id, style.version);
    if (_styles.containsKey(key)) {
      throw StateError('Style $key already has an owner.');
    }
    _styles[key] = style;
    return Registration(() {
      if (identical(_styles[key], style)) _styles.remove(key);
    });
  }

  GeoVisualRegistration addEffect(
    PluginContext context,
    GeoVisualPass pass, {
    required EffectBuilder build,
    bool enabled = true,
  }) {
    if (pass.stage != GeoVisualStage.effect ||
        pass.lifetime != GeoVisualLifetime.frame) {
      throw ArgumentError('Effects use frame outputs and the effect stage.');
    }
    return _install(
      context,
      pass,
      () => context.graph.addEffect(
        name: pass.name,
        after: pass.after,
        build: build,
        enabled: enabled,
      ),
    );
  }

  GeoVisualRegistration addCompute(
    PluginContext context,
    GeoVisualPass pass,
    ComputePassDescriptor descriptor, {
    Iterable<GpuResource<Object?>> inputs = const [],
    bool enabled = true,
  }) {
    _checkDescriptor(pass, descriptor);
    return _install(
      context,
      pass,
      () => context.graph.addCompute(
        descriptor,
        stage: _stage(pass.stage),
        inputs: inputs,
        enabled: enabled,
      ),
    );
  }

  GeoVisualRegistration addRender(
    PluginContext context,
    GeoVisualPass pass,
    RenderPassDescriptor descriptor, {
    Iterable<GpuResource<Object?>> inputs = const [],
    bool enabled = true,
  }) {
    _checkDescriptor(pass, descriptor);
    if ((pass.alpha == GeoVisualAlpha.opaque &&
            descriptor.blend != RenderBlend.replace) ||
        (pass.alpha == GeoVisualAlpha.premultiplied &&
            descriptor.blend != RenderBlend.premultipliedAlpha)) {
      throw ArgumentError(
        'Render blending must match the declared alpha convention.',
      );
    }
    return _install(
      context,
      pass,
      () => context.graph.addRender(
        descriptor,
        stage: _stage(pass.stage),
        inputs: inputs,
        enabled: enabled,
      ),
    );
  }

  static FramePassStage _stage(GeoVisualStage stage) => switch (stage) {
    GeoVisualStage.beforeScene => FramePassStage.beforeScene,
    GeoVisualStage.afterScene => FramePassStage.afterScene,
    GeoVisualStage.effect => throw ArgumentError(
      'Use addEffect for colour-chain contributions.',
    ),
  };
  void _checkDescriptor(GeoVisualPass pass, PassDescriptor descriptor) {
    _stage(pass.stage);
    if (descriptor.name != pass.name ||
        descriptor.after.length != pass.after.length ||
        !descriptor.after.containsAll(pass.after)) {
      throw ArgumentError(
        'Pass name and dependencies must match the GPU descriptor.',
      );
    }
  }

  GeoVisualRegistration _install(
    PluginContext context,
    GeoVisualPass pass,
    GraphRegistration Function() install,
  ) {
    if (context.scope.isClosed) {
      throw StateError('Visual attachment has closed.');
    }
    if (_passes.containsKey(pass.name)) {
      throw StateError('Pass ${pass.name} already has an owner.');
    }
    for (final feature in pass.requirements) {
      if (!context.capabilities.supports(feature)) {
        throw UnsupportedError(
          'Visual pass ${pass.name} requires ${feature.name}.',
        );
      }
    }
    if (pass.depthStrategy != null &&
        pass.depthStrategy != context.camera.depthStrategy) {
      throw StateError('Visual pass depth convention differs from the camera.');
    }
    validatePasses([..._passes.values, pass], requireDependencies: false);
    final graph = install();
    _passes[pass.name] = pass;
    final registration = GeoVisualRegistration._(graph, () {
      graph.dispose();
      if (identical(_passes[pass.name], pass)) _passes.remove(pass.name);
    });
    context.scope.keep(registration);
    return registration;
  }

  void validate({DepthStrategy? depthStrategy}) {
    validatePasses(_passes.values);
    if (depthStrategy != null &&
        _passes.values.any(
          (p) => p.depthStrategy != null && p.depthStrategy != depthStrategy,
        )) {
      throw StateError(
        'Active camera and visual pass depth conventions differ.',
      );
    }
  }

  static List<GeoVisualPass> validatePasses(
    Iterable<GeoVisualPass> passes, {
    bool requireDependencies = true,
  }) {
    final entries = passes.toList();
    if (entries.length > 128) {
      throw StateError('At most 128 visual passes are supported.');
    }
    final byName = <String, GeoVisualPass>{}, owners = <String, String>{};
    for (final pass in entries) {
      if (byName.containsKey(pass.name)) {
        throw StateError('Duplicate visual pass ${pass.name}.');
      }
      byName[pass.name] = pass;
      for (final key in pass.exclusive) {
        if (owners.containsKey(key)) {
          throw StateError(
            'Exclusive visual capability $key has multiple owners.',
          );
        }
        owners[key] = pass.owner;
      }
    }
    final ordered = <GeoVisualPass>[], active = <String>{}, done = <String>{};
    void visit(GeoVisualPass pass) {
      if (done.contains(pass.name)) return;
      if (!active.add(pass.name)) {
        throw StateError('Visual pass dependency cycle at ${pass.name}.');
      }
      for (final dependency in pass.after.toList()..sort()) {
        final previous = byName[dependency];
        if (previous == null) {
          if (requireDependencies) {
            throw StateError('Missing visual pass $dependency.');
          }
        } else {
          if (previous.stage != pass.stage) {
            throw StateError(
              'Explicit pass dependencies must stay in the same graph stage.',
            );
          }
          visit(previous);
        }
      }
      active.remove(pass.name);
      done.add(pass.name);
      ordered.add(pass);
    }

    for (final name in byName.keys.toList()..sort()) {
      visit(byName[name]!);
    }
    return List.unmodifiable(ordered);
  }
}
