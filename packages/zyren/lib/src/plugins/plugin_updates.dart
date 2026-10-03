part of 'engine.dart';

/// A live update failed. [activePluginIds] names the remaining usable graph.
/// You can retry with a complete configuration after handling the cause.
class PluginUpdateException implements Exception {
  final Object cause;
  final List<Object> cleanupErrors;
  final List<String> activePluginIds;
  PluginUpdateException(
    this.cause,
    Iterable<Object> cleanupErrors,
    Iterable<String> activePluginIds,
  ) : cleanupErrors = List.unmodifiable(cleanupErrors),
      activePluginIds = List.unmodifiable(activePluginIds);
  @override
  String toString() =>
      'Plugin update failed: $cause; active: $activePluginIds'
      '${cleanupErrors.isEmpty ? '' : '; cleanup: $cleanupErrors'}';
}

extension _PluginUpdates on SceneEngine {
  Future<void> _hook(FutureOr<void> Function() callback) => runZoned(
    () => Future<void>.sync(callback),
    zoneValues: {SceneEngine._hookZone: this},
  );

  Future<void> _queuePlugins(List<ScenePlugin> plugins) {
    if (_closed) return Future.error(StateError('Engine has been disposed.'));
    if (identical(Zone.current[SceneEngine._hookZone], this)) {
      return Future.error(StateError('Update plugins outside engine hooks.'));
    }
    final requested = List<ScenePlugin>.of(plugins);
    _pendingPluginUpdates++;
    final result = _pluginUpdates
        .then((_) => _reconcilePlugins(requested))
        .whenComplete(() {
          _pendingPluginUpdates--;
          if (!_closed) _onInvalidate?.call();
        });
    // This tail never rejects. Each caller still receives its own failure.
    _pluginUpdates = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  PluginContext _contextFor(ScenePlugin plugin) => PluginContext._(
    plugin.id,
    _backend,
    scene,
    camera,
    capabilities,
    _services,
    _onInvalidate,
    _acquireFrameDemand,
    _input,
    () => _claimFrameGraph(plugin.id),
    _claimGraph,
    () => _claimEnvironment(plugin.id),
    () => _claimTemporal(plugin.id),
  );

  Future<void> _removeAttachment(
    (ScenePlugin, PluginContext) attachment,
    List<Object> errors, {
    bool releaseOwnership = true,
  }) async {
    final (plugin, context) = attachment;
    try {
      context.scope.close();
    } catch (_) {
      /* whenClosed reports it. */
    }
    try {
      await context.scope.whenClosed;
    } catch (error) {
      errors.add(error);
    }
    try {
      await _hook(() => plugin.detach(context));
    } catch (error) {
      errors.add(error);
    } finally {
      context._close();
      _attached.remove(attachment);
      if (releaseOwnership && identical(SceneEngine._owners[plugin], _owner)) {
        SceneEngine._owners[plugin] = null;
      }
    }
  }

  Future<void> _releaseUnusedGraph(List<Object> errors) async {
    if (_sharedGraph == null ||
        _attached.any((entry) => entry.$2._graph != null)) {
      return;
    }
    final graph = _sharedGraph;
    _sharedGraph = null;
    try {
      await graph!.close();
    } catch (error) {
      errors.add(error);
    }
  }

  Future<void> _reconcilePlugins(List<ScenePlugin> requested) async {
    if (_closed) throw _cancelled();
    final ordered = SceneEngine._resolve(requested);
    for (final plugin in ordered) {
      final owner = SceneEngine._owners[plugin];
      if (owner != null && !identical(owner, _owner)) {
        throw StateError(
          'Plugin ${plugin.id} is already attached to an engine.',
        );
      }
      final missing = plugin.requiredFeatures.difference(capabilities.features);
      if (missing.isNotEmpty) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.unsupportedFeature,
            operation: 'attach',
            pluginId: plugin.id,
            requiredFeatures: Set.unmodifiable(missing),
            limits: capabilities.limits,
            message: 'Plugin ${plugin.id} requires unsupported features.',
          ),
        );
      }
    }
    // Reserve candidates before yielding so another engine cannot acquire them.
    for (final plugin in ordered) {
      SceneEngine._owners[plugin] = _owner;
    }
    final added = <(ScenePlugin, PluginContext)>[];
    final errors = <Object>[];
    try {
      try {
        await _frame;
      } catch (_) {
        /* The frame caller receives this. */
      }
      if (_closed) throw _cancelled();
      final nextById = {for (final plugin in ordered) plugin.id: plugin};
      final affected = <String>{
        for (final plugin in _plugins)
          if (!identical(nextById[plugin.id], plugin)) plugin.id,
      };
      var changed = true;
      while (changed) {
        changed = false;
        for (final plugin in _plugins) {
          if (!affected.contains(plugin.id) &&
              plugin.dependencies.any(affected.contains)) {
            affected.add(plugin.id);
            changed = true;
          }
        }
      }
      for (final attachment in _attached.reversed.toList()) {
        if (affected.contains(attachment.$1.id)) {
          await _removeAttachment(
            attachment,
            errors,
            releaseOwnership: !ordered.any((p) => identical(p, attachment.$1)),
          );
        }
      }
      await _releaseUnusedGraph(errors);
      if (errors.isNotEmpty) throw EngineCleanupException(errors.toList());
      for (final plugin in ordered) {
        if (_closed) throw _cancelled();
        if (_attached.any((entry) => identical(entry.$1, plugin))) continue;
        SceneEngine._owners[plugin] = _owner;
        final context = _contextFor(plugin);
        final attachment = (plugin, context);
        _attached.add(attachment);
        added.add(attachment);
        try {
          await _hook(() => plugin.attach(context));
        } finally {
          context._registering = false;
        }
        if (_closed) throw _cancelled();
      }
      final contexts = {for (final entry in _attached) entry.$1: entry.$2};
      _attached
        ..clear()
        ..addAll(ordered.map((plugin) => (plugin, contexts[plugin]!)));
      _plugins = ordered;
    } catch (error) {
      for (final attachment in added.reversed) {
        await _removeAttachment(attachment, errors);
      }
      await _releaseUnusedGraph(errors);
      _plugins = _attached.map((entry) => entry.$1).toList();
      throw PluginUpdateException(error, errors, pluginIds);
    } finally {
      for (final plugin in ordered) {
        if (!_attached.any((entry) => identical(entry.$1, plugin)) &&
            identical(SceneEngine._owners[plugin], _owner)) {
          SceneEngine._owners[plugin] = null;
        }
      }
    }
  }
}
