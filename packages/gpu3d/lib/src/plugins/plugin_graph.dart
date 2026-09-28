part of 'engine.dart';

/// Last successful shared composition and its most recent candidate failure.
final class SceneGraphState {
  final PhysicalSize? size;
  final int builds, historyFrames, historyGeneration;
  final SceneIssue? issue;
  const SceneGraphState({
    this.size,
    this.builds = 0,
    this.issue,
    this.historyFrames = 0,
    this.historyGeneration = 0,
  });
}

/// A removable contribution. Changes rebuild the graph at the next frame.
final class GraphRegistration extends Registration {
  final void Function() _check, _changed;
  bool _enabled;
  GraphRegistration._(super.release, this._check, this._changed, this._enabled);
  bool get enabled => !isDisposed && _enabled;
  set enabled(bool value) {
    _checkOpen();
    if (_enabled == value) return;
    _enabled = value;
    _changed();
  }

  /// Rebuild after changing a pass layout or a value captured by its builder.
  /// Uniform uploads only need PluginContext.invalidate, without rebuilding.
  void invalidate() {
    _checkOpen();
    _changed();
  }

  void _checkOpen() {
    if (isDisposed) throw StateError('Graph registration has been disposed.');
    _check();
  }
}

/// A build's resources close after compilation, success or failure. Compiled
/// ownership keeps accepted resources alive. Keep persistent uniforms in your
/// plugin's attachment scope, not in this temporary scope.
final class EffectBuildContext {
  final PhysicalSize size;
  final GpuResource<Texture> input;
  final ResourceScope resources;
  final _HistoryCandidate _history;
  EffectBuildContext._(this.size, this.input, this.resources, this._history);

  /// Creates two persistent textures. Write current, sample previous and use
  /// TextureHistoryState.validFrames to reject samples after invalidation.
  Future<TextureHistory> createHistory({
    String label = '',
    TextureFormat? format,
    Set<TextureUsage> usage = const {
      TextureUsage.sampled,
      TextureUsage.renderAttachment,
    },
  }) => _history.create(
    size,
    format ?? (input.descriptor as TextureDescriptor).format,
    label,
    usage,
  );

  Future<GpuResource<Texture>> createColorTexture({
    String label = '',
    TextureFormat? format,
    Set<TextureUsage> usage = const {
      TextureUsage.sampled,
      TextureUsage.renderAttachment,
    },
  }) => resources.createTexture(
    TextureDescriptor(
      label: label,
      width: size.width,
      height: size.height,
      format: format ?? (input.descriptor as TextureDescriptor).format,
      usage: usage,
    ),
  );
}

/// One effect's passes and the texture passed to the next enabled effect.
final class GraphEffect {
  final GpuResource<Texture> output;
  final List<PassDescriptor> passes;
  final List<GpuResource<Object?>> inputs;
  GraphEffect({
    required this.output,
    required Iterable<PassDescriptor> passes,
    Iterable<GpuResource<Object?>> inputs = const [],
  }) : passes = List.unmodifiable(passes),
       inputs = List.unmodifiable(inputs);
}

typedef EffectBuilder =
    FutureOr<GraphEffect> Function(EffectBuildContext frame);

/// Contributions to one view's shared native frame graph. Register during attach;
/// the attachment owns each returned handle, including partial attach rollback.
final class PluginGraph {
  final PluginContext _context;
  final _SharedFrameGraph _owner;
  PluginGraph._(this._context, this._owner);
  SceneGraphState get state => _owner.state;

  /// Resets temporal samples without rebuilding programs or reallocating textures.
  void invalidateHistory() {
    _context._checkAttached();
    _owner.invalidateHistory();
    _context.invalidate();
  }

  GraphRegistration addCompute(
    ComputePassDescriptor pass, {
    FramePassStage stage = FramePassStage.beforeScene,
    Iterable<GpuResource<Object?>> inputs = const [],
    bool enabled = true,
  }) => _add(
    pass.name,
    pass: pass,
    stage: stage,
    inputs: inputs,
    enabled: enabled,
  );

  GraphRegistration addRender(
    RenderPassDescriptor pass, {
    FramePassStage stage = FramePassStage.beforeScene,
    Iterable<GpuResource<Object?>> inputs = const [],
    bool enabled = true,
  }) => _add(
    pass.name,
    pass: pass,
    stage: stage,
    inputs: inputs,
    enabled: enabled,
  );

  /// Effects form a color chain. Dependencies name effects, not individual passes.
  GraphRegistration addEffect({
    required String name,
    required EffectBuilder build,
    Set<String> after = const {},
    bool enabled = true,
  }) => _add(name, build: build, after: after, enabled: enabled);

  GraphRegistration _add(
    String name, {
    PassDescriptor? pass,
    FramePassStage stage = FramePassStage.beforeScene,
    Iterable<GpuResource<Object?>> inputs = const [],
    EffectBuilder? build,
    Set<String> after = const {},
    required bool enabled,
  }) {
    _context._checkAttached();
    if (!_context._registering) {
      throw StateError('Register graph contributions during attach.');
    }
    if (pass != null) _owner._checkFeatures(pass, _context._pluginId);
    final entry = _GraphContribution(
      name,
      _context._pluginId,
      pass,
      stage,
      List.unmodifiable(inputs),
      build,
      Set.unmodifiable(after),
    );
    final registration = _owner._add(entry, _context, enabled);
    return _context.scope.keep(registration) as GraphRegistration;
  }
}

final class _GraphContribution {
  final String name, pluginId;
  final PassDescriptor? pass;
  final FramePassStage stage;
  final List<GpuResource<Object?>> inputs;
  final EffectBuilder? build;
  final Set<String> after;
  late GraphRegistration registration;
  _GraphContribution(
    this.name,
    this.pluginId,
    this.pass,
    this.stage,
    this.inputs,
    this.build,
    this.after,
  );
}

final class _SharedFrameGraph {
  final GraphBackend backend;
  final void Function(SceneIssue)? onIssue;
  final _entries = <_GraphContribution>[];
  final _cleanupErrors = <Object>[];
  GraphCompiler? _compiler, _alternate;
  _HistoryCandidate? _history;
  int _historyFrames = 0, _historyGeneration = 0, _historyIndex = 0;
  int _preparedGeneration = -1;
  CompiledGraph? _preparedGraph;
  List<double>? _projection;
  int _revision = 0, _builtRevision = -1;
  (int, int, int)? _failed;
  Object? _failure;
  StackTrace? _failureStack;
  bool _stopped = false;
  SceneGraphState state = const SceneGraphState();
  _SharedFrameGraph(this.backend, this.onIssue);

  GraphRegistration _add(
    _GraphContribution entry,
    PluginContext context,
    bool enabled,
  ) {
    if (_stopped) throw StateError('Shared frame graph has closed.');
    if (entry.name.isEmpty || utf8.encode(entry.name).length > 1024) {
      throw GraphException(
        GraphErrorCode.invalidDescriptor,
        'Contribution names need 1 to 1024 UTF-8 bytes.',
        passName: entry.name,
      );
    }
    if (_entries.any((e) => e.name == entry.name)) {
      throw GraphException(
        GraphErrorCode.duplicatePass,
        'Duplicate graph contribution.',
        passName: entry.name,
      );
    }
    if (_entries.length >= 128) {
      throw GraphException(
        GraphErrorCode.limitExceeded,
        'At most 128 graph contributions are supported.',
      );
    }
    void changed() {
      _revision++;
      if (!_stopped) context._invalidate?.call();
    }

    entry.registration = GraphRegistration._(
      () {
        _entries.remove(entry);
        changed();
      },
      context._checkAttached,
      changed,
      enabled,
    );
    _entries.add(entry);
    changed();
    return entry.registration;
  }

  void _checkFeatures(PassDescriptor pass, String pluginId) {
    final required = {
      if (pass is ComputePassDescriptor) RenderFeature.compute,
      if (pass.bindings.entries.whereType<TextureBinding>().any(
        (b) => b.storage,
      ))
        RenderFeature.storageTextures,
    };
    final missing = required.difference(backend.capabilities.features);
    if (missing.isNotEmpty) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.unsupportedFeature,
          message: 'Graph pass requires unsupported features.',
          operation: 'graph',
          pluginId: pluginId,
          resourceLabel: pass.name,
          requiredFeatures: missing,
          limits: backend.capabilities.limits,
        ),
      );
    }
  }

  List<_GraphContribution> _effects(List<_GraphContribution> entries) {
    final effects = {
      for (final e in entries)
        if (e.build != null) e.name: e,
    };
    final visiting = <String>{}, visited = <String>{};
    final ordered = <_GraphContribution>[];
    void visit(String name) {
      if (visited.contains(name)) return;
      final entry = effects[name];
      if (entry == null) {
        throw GraphException(
          GraphErrorCode.missingDependency,
          'Unknown effect dependency $name.',
          passName: name,
        );
      }
      if (!visiting.add(name)) {
        throw GraphException(
          GraphErrorCode.cycle,
          'Effect dependencies form a cycle.',
          passName: name,
        );
      }
      for (final dependency in entry.after) {
        visit(dependency);
      }
      visiting.remove(name);
      visited.add(name);
      if (entry.registration.enabled) ordered.add(entry);
    }

    for (final name in effects.keys) {
      visit(name);
    }
    return ordered;
  }

  bool _matches(PhysicalSize size) =>
      state.size?.width == size.width && state.size?.height == size.height;

  void stop() {
    _stopped = true;
  }

  void _checkCurrent(int revision) {
    if (_stopped) throw StateError('Shared frame graph has closed.');
    if (revision != _revision) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.frameDeferred,
          message:
              'Graph contributions changed while compiling. Retry the frame.',
          operation: 'graph',
        ),
      );
    }
  }

  void _historyState() {
    state = SceneGraphState(
      size: state.size,
      builds: state.builds,
      issue: state.issue,
      historyFrames: _historyFrames,
      historyGeneration: _historyGeneration,
    );
  }

  void invalidateHistory() {
    if (_stopped) throw StateError('Shared frame graph has closed.');
    _historyFrames = 0;
    _historyIndex = 0;
    _historyGeneration = (_historyGeneration + 1) & 0xffffffff;
    _historyState();
  }

  Future<CompiledGraph?> prepare(
    PhysicalSize size,
    List<double> projection,
  ) async {
    await _prepareGraph(size);
    if (_projection case final previous?
        when previous.length != projection.length ||
            List.generate(
              previous.length,
              (i) => i,
            ).any((i) => previous[i] != projection[i])) {
      invalidateHistory();
    }
    _projection = projection;
    final generation = _historyGeneration;
    await _history?.writeState(_historyFrames, generation);
    if (_stopped || generation != _historyGeneration) {
      throw SceneException(
        SceneIssue(
          code: SceneIssueCodes.frameDeferred,
          message: 'History changed during frame preparation. Retry the frame.',
          operation: 'graph',
        ),
      );
    }
    _preparedGeneration = generation;
    return _preparedGraph = _historyIndex == 0
        ? _compiler?.active
        : _alternate?.active;
  }

  void completeFrame(CompiledGraph? graph) {
    if (_history?.textures.isEmpty ?? true) return;
    if (_preparedGeneration != _historyGeneration ||
        !identical(graph, _preparedGraph)) {
      return;
    }
    _historyIndex = 1 - _historyIndex;
    if (_historyFrames < 0xffffffff) _historyFrames++;
    _historyState();
  }

  Future<CompiledGraph?> _prepareGraph(PhysicalSize size) async {
    _checkCurrent(_revision);
    if (_failed case final failed?
        when failed.$2 != size.width || failed.$3 != size.height) {
      _failed = null;
    }
    if (_builtRevision == _revision && _matches(size)) return _compiler?.active;
    final revision = _revision, key = (_revision, size.width, size.height);
    if (_failed == key) {
      if (_builtRevision >= 0 && _matches(size)) return _compiler?.active;
      Error.throwWithStackTrace(_failure!, _failureStack!);
    }
    ResourceScope? resources;
    GraphCompiler? candidate, alternate;
    _HistoryCandidate? history;
    try {
      final entries = _entries.toList();
      final effects = _effects(entries);
      final fixed = entries
          .where((e) => e.pass != null && e.registration.enabled)
          .toList();
      if (fixed.isNotEmpty || effects.isNotEmpty) {
        history = _HistoryCandidate(
          backend.createResourceScope(label: 'frame history'),
        );
        resources = backend.createResourceScope(
          label: 'shared frame candidate',
        );
        final scene = await resources.createTexture(
          TextureDescriptor(
            label: 'shared scene color',
            width: size.width,
            height: size.height,
            usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
          ),
        );
        _checkCurrent(revision);
        final before = <PassDescriptor>[], after = <PassDescriptor>[];
        final inputs = <GpuResource<Object?>>[];
        for (final entry in fixed) {
          (entry.stage == FramePassStage.beforeScene ? before : after).add(
            entry.pass!,
          );
          inputs.addAll(entry.inputs);
        }
        var output = scene;
        for (final entry in effects) {
          final effectScope = resources.createChild(label: entry.name);
          final GraphEffect effect;
          try {
            effect = await entry.build!(
              EffectBuildContext._(size, output, effectScope, history),
            );
          } catch (error) {
            _checkCurrent(revision);
            throw SceneException(
              SceneIssue(
                code: 'graph.effectBuildFailed',
                message: 'Could not build effect ${entry.name}: $error',
                operation: 'graph',
                pluginId: entry.pluginId,
                resourceLabel: entry.name,
                cause: error,
              ),
            );
          }
          _checkCurrent(revision);
          final descriptor = effect.output.descriptor as TextureDescriptor;
          if (descriptor.width != size.width ||
              descriptor.height != size.height ||
              descriptor.mipLevels != 1 ||
              !descriptor.usage.contains(TextureUsage.sampled)) {
            throw GraphException(
              GraphErrorCode.invalidDescriptor,
              'Effect output must be a sampled, single-mip texture matching the frame.',
              passName: entry.name,
            );
          }
          for (final pass in effect.passes) {
            _checkFeatures(pass, entry.pluginId);
          }
          after.addAll(effect.passes);
          inputs.addAll(effect.inputs);
          output = effect.output;
        }
        if (before.isNotEmpty || after.isNotEmpty) {
          candidate = backend.createGraphCompiler(label: 'shared frame');
          final description = GraphDescription(
            label: 'shared frame',
            sceneColor: scene,
            output: output,
            beforeScene: before,
            passes: after,
            inputs: [
              ...inputs,
              for (final texture in history.textures) texture.previous,
              if (history.uniforms != null) history.uniforms!,
            ],
          );
          final swapped = history.textures.isEmpty
              ? null
              : swapHistoryTextures(
                  description,
                  history.textures.map((t) => (t.previous, t.current)),
                );
          await candidate.compile(description);
          _checkCurrent(revision);
          if (swapped != null) {
            alternate = backend.createGraphCompiler(
              label: 'shared frame alternate',
            );
            await alternate.compile(swapped);
          }
        } else if (!identical(output, scene)) {
          throw GraphException(
            GraphErrorCode.uninitializedRead,
            'An effect without passes must return its input.',
          );
        }
        await resources.close();
        resources = null;
      }
      _checkCurrent(revision);
      final previous = _compiler, previousAlternate = _alternate;
      final previousHistory = _history;
      _compiler = candidate;
      _alternate = alternate;
      _history = history;
      candidate = null;
      alternate = null;
      history = null;
      _projection = null;
      invalidateHistory();
      _builtRevision = revision;
      _failed = null;
      _failure = null;
      _failureStack = null;
      state = SceneGraphState(
        size: size,
        builds: state.builds + 1,
        historyGeneration: _historyGeneration,
      );
      try {
        await previous?.close();
      } catch (error) {
        _cleanupErrors.add(error);
      }
      try {
        await previousAlternate?.close();
      } catch (error) {
        _cleanupErrors.add(error);
      }
      try {
        await previousHistory?.close();
      } catch (error) {
        _cleanupErrors.add(error);
      }
      _checkCurrent(revision);
      return _compiler?.active;
    } catch (error, stack) {
      final failures = <Object>[];
      try {
        await candidate?.close();
      } catch (error) {
        failures.add(error);
      }
      try {
        await alternate?.close();
      } catch (error) {
        failures.add(error);
      }
      try {
        await history?.close();
      } catch (error) {
        failures.add(error);
      }
      try {
        await resources?.close();
      } catch (error) {
        failures.add(error);
      }
      if (failures.isNotEmpty) _cleanupErrors.addAll(failures);
      _checkCurrent(revision);
      _failed = key;
      _failure = error;
      _failureStack = stack;
      final issue = error is SceneException
          ? error.issue
          : SceneIssue(
              code: SceneIssueCodes.renderFailed,
              message: error.toString(),
              operation: 'graph',
              cause: error,
            );
      state = SceneGraphState(
        size: state.size,
        builds: state.builds,
        issue: issue,
        historyFrames: _historyFrames,
        historyGeneration: _historyGeneration,
      );
      if (_builtRevision >= 0 && _matches(size)) {
        try {
          onIssue?.call(issue);
        } catch (error) {
          _cleanupErrors.add(error);
        }
        return _compiler?.active;
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> close() async {
    stop();
    try {
      await _compiler?.close();
    } catch (error) {
      _cleanupErrors.add(error);
    }
    try {
      await _alternate?.close();
    } catch (error) {
      _cleanupErrors.add(error);
    }
    try {
      await _history?.close();
    } catch (error) {
      _cleanupErrors.add(error);
    }
    _compiler = null;
    _alternate = null;
    _history = null;
    _entries.clear();
    if (_cleanupErrors.isNotEmpty) throw ScopeCleanupException(_cleanupErrors);
  }
}
