part of '../flutter_zyren_studio.dart';

final class _Owned<T> {
  final T value;
  final StudioEditorContext context;
  _Owned(this.value, this.context);
}

final class _ContributionLease {
  final StudioEditorContribution contribution;
  final scope = AttachmentScope();
  final plugins = <ScenePlugin>[];
  late StudioEditorContext context;
  bool runtimeUsed = false, runtimeReady = true;
  _ContributionLease(this.contribution);
}

final class StudioEditorHostController extends ChangeNotifier {
  final StudioEditorServices services;
  final Set<String> reservedPanelIds;
  final Set<String> _reservedShortcuts;
  final _contributions = <String, _ContributionLease>{};
  final _panels = <String, _Owned<StudioEditorPanel>>{};
  final _placements = <String, _Owned<StudioEditorPlacement>>{};
  final _inspectors = <String, _Owned<StudioEditorInspector>>{};
  final _assetKinds = <String, _Owned<StudioEditorAssetKind>>{};
  final _commands = <String, _Owned<StudioEditorCommand>>{};
  final _creationTools = <String, _Owned<StudioEditorCreationTool>>{};
  final _overlays = <String, _Owned<StudioEditorOverlay>>{};
  final _validators = <String, _Owned<StudioEditorValidator>>{};
  final _playFactories = <String, _Owned<StudioEditorPlayFactory>>{};
  final _cleanup = <Future<void>>{};
  final _cleanupErrors = <Object>[];
  Future<void> _runtimeSync = Future.value();
  bool _closed = false, _mutating = false;
  int _commandSequence = 0, _playEpoch = 0;
  String? _startingFactory, _activeFactory;
  StudioEditorPlaySession? _playSession;
  Object? lastError;

  StudioEditorHostController({
    required this.services,
    Set<String> reservedPanelIds = const {},
    Iterable<SingleActivator> reservedShortcuts = const [],
  }) : reservedPanelIds = Set.unmodifiable(reservedPanelIds),
       _reservedShortcuts = reservedShortcuts.map(_shortcutSignature).toSet();

  List<String> get contributionIds => List.unmodifiable(_contributions.keys);
  List<String> get panelIds => List.unmodifiable(_panels.keys);
  List<String> get placementIds => List.unmodifiable(_placements.keys);
  StudioEditorPlacementBinding? get placementForSelection {
    final candidates =
        _placements.values
            .where(
              (entry) =>
                  entry.context.isActive &&
                  entry.context._owner.runtimeReady &&
                  entry.value.applies(entry.context),
            )
            .toList()
          ..sort((a, b) {
            final priority = b.value.priority.compareTo(a.value.priority);
            return priority != 0 ? priority : a.value.id.compareTo(b.value.id);
          });
    if (candidates.isEmpty) return null;
    final entry = candidates.first;
    return StudioEditorPlacementBinding._(entry.value, entry.context);
  }

  List<String> get inspectorIds => List.unmodifiable(_inspectors.keys);
  List<String> get assetKindIds => List.unmodifiable(_assetKinds.keys);
  List<String> get commandIds => List.unmodifiable(_commands.keys);
  List<String> get creationToolIds => List.unmodifiable(_creationTools.keys);
  List<String> get overlayIds => List.unmodifiable(_overlays.keys);
  List<String> get validatorIds => List.unmodifiable(_validators.keys);
  List<String> get playFactoryIds => List.unmodifiable(_playFactories.keys);
  StudioEditorPlaySession? get activePlaySession => _playSession;
  Future<void> get whenSettled async {
    await _runtimeSync;
    await Future.wait(_cleanup.toList());
    if (_cleanupErrors.isNotEmpty) throw ScopeCleanupException(_cleanupErrors);
  }

  void refresh() {
    _check();
    notifyListeners();
  }

  void _check() {
    if (_closed) throw StateError('Editor contribution host is closed.');
  }

  void _changed() {
    if (!_closed && !_mutating) {
      notifyListeners();
      services.onChanged?.call();
    }
  }

  Registration _register<T>(
    Map<String, _Owned<T>> map,
    String id,
    T value,
    StudioEditorContext context,
  ) {
    _check();
    if (map.containsKey(id)) {
      throw StateError('Duplicate editor registration: $id.');
    }
    if (map.length >= 4096) {
      throw StateError('Editor registration capacity reached.');
    }
    final entry = _Owned(value, context);
    map[id] = entry;
    final registration = Registration(() {
      if (identical(map[id], entry)) {
        map.remove(id);
        _changed();
      }
    });
    context.scope.keep(registration);
    _changed();
    return registration;
  }

  Registration register(StudioEditorContribution contribution) =>
      registerAll([contribution]);

  Registration registerAll(List<StudioEditorContribution> contributions) {
    _check();
    if (_mutating) {
      throw StateError('Do not register contributions during attachment.');
    }
    if (_contributions.length + contributions.length > 256) {
      throw StateError('Contribution capacity reached.');
    }
    final pending = <String, StudioEditorContribution>{};
    for (final contribution in contributions) {
      if (_contributions.containsKey(contribution.id) ||
          pending.containsKey(contribution.id)) {
        throw StateError('Duplicate contribution: ${contribution.id}.');
      }
      pending[contribution.id] = contribution;
    }
    final ordered = <StudioEditorContribution>[];
    final visiting = <String>{}, visited = <String>{};
    void visit(String id) {
      if (_contributions.containsKey(id) || visited.contains(id)) return;
      final contribution = pending[id];
      if (contribution == null) {
        throw StateError('Missing contribution dependency: $id.');
      }
      if (!visiting.add(id)) {
        throw StateError('Contribution dependency cycle: $id.');
      }
      for (final dependency in contribution.dependencies) {
        visit(dependency);
      }
      visiting.remove(id);
      visited.add(id);
      ordered.add(contribution);
    }

    for (final id in pending.keys) {
      visit(id);
    }
    final added = <_ContributionLease>[];
    _mutating = true;
    try {
      for (final contribution in ordered) {
        final owner = _ContributionLease(contribution);
        final agents = StudioAgentExtensionContext(
          scene: services.scene,
          agents: services.agents,
          isAvailable: () => owner.context.isAvailable,
          onChanged: _changed,
          usePlugin: owner.plugins.add,
          deferRegistration: true,
        );
        owner.scope.keep(Registration(agents.dispose));
        owner.context = StudioEditorContext._(this, owner, owner.scope, agents);
        _contributions[contribution.id] = owner;
        added.add(owner);
        if (contribution.runtimeExtension case final extension?) {
          owner.runtimeUsed = true;
          extension.attach(agents);
        }
        contribution.attach(owner.context);
        if (owner.runtimeUsed || owner.plugins.isNotEmpty) {
          if (services.installRuntimePlugins == null) {
            throw StateError('Runtime plugin attachment is unavailable.');
          }
          owner.runtimeReady = false;
          owner.plugins.add(
            agents.binding(
              'studio.editor.binding.${contribution.id}',
              owner.plugins.map((p) => p.id),
            ),
          );
        }
      }
      final pluginIds = <String>{};
      for (final owner in _contributions.values) {
        for (final plugin in owner.plugins) {
          if (!pluginIds.add(plugin.id)) {
            throw StateError(
              'Duplicate contributed scene plugin: ${plugin.id}.',
            );
          }
        }
      }
    } catch (_) {
      for (final owner in added.reversed) {
        _removeOne(owner);
      }
      rethrow;
    } finally {
      _mutating = false;
      _changed();
    }
    if (added.any((e) => e.plugins.isNotEmpty)) _syncRuntime(added);
    return Registration(() {
      for (final owner in added.reversed) {
        _remove(owner.contribution.id);
      }
    });
  }

  void _removeOne(_ContributionLease owner) {
    if (!identical(_contributions[owner.contribution.id], owner)) return;
    _contributions.remove(owner.contribution.id);
    try {
      owner.scope.close();
    } catch (error) {
      lastError = error;
    } finally {
      _trackCleanup(owner.scope.whenClosed);
    }
  }

  void _remove(String id) {
    final owner = _contributions[id];
    if (owner == null) return;
    final dependents = _contributions.values
        .where((e) => e.contribution.dependencies.contains(id))
        .toList();
    for (final dependent in dependents.reversed) {
      _remove(dependent.contribution.id);
    }
    _removeOne(owner);
    _changed();
    if (owner.plugins.isNotEmpty) _syncRuntime(const []);
  }

  void _syncRuntime(List<_ContributionLease> candidates) {
    final installer = services.installRuntimePlugins!;
    final prior = _runtimeSync;
    _runtimeSync = prior
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .then((_) async {
          try {
            await installer(
              List.unmodifiable([
                for (final e in _contributions.values) ...e.plugins,
              ]),
            );
            for (final owner in _contributions.values) {
              owner.runtimeReady = true;
            }
            _changed();
          } catch (error) {
            lastError = error;
            for (final candidate in candidates.reversed) {
              if (identical(
                _contributions[candidate.contribution.id],
                candidate,
              )) {
                _remove(candidate.contribution.id);
              }
            }
            await installer(
              List.unmodifiable([
                for (final e in _contributions.values) ...e.plugins,
              ]),
            );
            _changed();
            rethrow;
          }
        });
    _runtimeSync.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  Future<void> executeCommand(String id) async {
    _check();
    final entry = _commands[id];
    if (entry == null ||
        !entry.context.isAvailable ||
        !entry.value.enabled(entry.context)) {
      throw StateError('Editor command is unavailable: $id.');
    }
    await entry.value.handler(entry.context);
    _changed();
  }

  Future<void> create(String id) async {
    _check();
    final entry = _creationTools[id];
    if (entry == null ||
        !entry.context.isAvailable ||
        !entry.value.enabled(entry.context)) {
      throw StateError('Creation tool is unavailable: $id.');
    }
    await entry.value.create(entry.context);
    _changed();
  }

  Future<void> importAsset(String kindId, Uri source) async {
    _check();
    final entry = _assetKinds[kindId];
    if (entry == null || !entry.context.isAvailable) {
      throw StateError('Asset importer is unavailable.');
    }
    final extension = source.path.split('.').last.toLowerCase();
    if (!entry.value.extensions.contains(extension)) {
      throw ArgumentError('Unsupported asset extension.');
    }
    await entry.value.importAsset(entry.context, source);
    _changed();
  }

  Future<List<StudioEditorProblem>> validate({StudioDocument? document}) async {
    _check();
    final snapshot = document ?? services.scene.capture();
    final results = <StudioEditorProblem>[];
    for (final entry in List.of(_validators.values)) {
      final problems = await entry.value.validate(entry.context, snapshot);
      if (entry.context.isActive && _validators[entry.value.id] == entry) {
        if (results.length + problems.length > 4096) {
          throw StateError('Validation result capacity reached.');
        }
        results.addAll(problems);
      }
    }
    return List.unmodifiable(results);
  }

  Future<void> startPlay(String id) async {
    _check();
    final entry = _playFactories[id];
    final document = services.scene.capture();
    if (entry == null ||
        !entry.context.isAvailable ||
        !entry.value.supports(entry.context, document)) {
      throw StateError('Play factory is unavailable.');
    }
    final epoch = ++_playEpoch;
    _startingFactory = id;
    try {
      final problems = await validate(document: document);
      if (problems.any((p) => p.blocking)) {
        throw StateError('Resolve blocking project validation before play.');
      }
      if (_closed ||
          epoch != _playEpoch ||
          !entry.context.isActive ||
          !identical(_playFactories[id], entry)) {
        throw StateError('Play request retired.');
      }
      final session = await entry.value.create(entry.context, document);
      if (_closed ||
          epoch != _playEpoch ||
          !entry.context.isActive ||
          !identical(_playFactories[id], entry)) {
        await session.close();
        throw StateError('Play request retired.');
      }
      final old = _playSession;
      _playSession = session;
      _activeFactory = id;
      if (old != null) await old.close();
      _changed();
    } finally {
      if (epoch == _playEpoch) _startingFactory = null;
    }
  }

  Future<void> stopPlay() async {
    ++_playEpoch;
    _startingFactory = null;
    _activeFactory = null;
    final old = _playSession;
    _playSession = null;
    if (old != null) await old.close();
    _changed();
  }

  Future<void> pausePlay() async {
    _check();
    final session = _playSession;
    if (session == null) throw StateError('No play session.');
    await session.pause();
    _changed();
  }

  Future<void> resumePlay() async {
    _check();
    final session = _playSession;
    if (session == null) throw StateError('No play session.');
    await session.resume();
    _changed();
  }

  Future<void> stepPlay() async {
    _check();
    final session = _playSession;
    if (session == null || !session.isPaused) {
      throw StateError('Pause the play session before stepping.');
    }
    await session.step();
    _changed();
  }

  void _trackCleanup(Future<void> future) {
    _cleanup.add(future);
    future.then<void>(
      (_) {
        _cleanup.remove(future);
      },
      onError: (Object error, StackTrace _) {
        _cleanup.remove(future);
        if (_cleanupErrors.length < 64) _cleanupErrors.add(error);
        lastError = error;
        _changed();
      },
    );
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final owner in _contributions.values.toList().reversed) {
      _removeOne(owner);
    }
    _trackCleanup(stopPlay());
    if (services.installRuntimePlugins != null) _syncRuntime(const []);
    super.dispose();
  }

  Future<void> close() async {
    dispose();
    await whenSettled;
  }
}
