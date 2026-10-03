part of '../flutter_zyren_studio.dart';

/// All services belong to the existing editor. This object never grants scopes.
final class StudioEditorServices {
  final StudioScene scene;
  final StudioCommands commands;
  final AgentRegistry agents;
  final StudioAssetResolver? assets;
  final SceneController? viewportController;
  final bool Function() isAvailable;
  final Map<String, Object?> Function() viewportSnapshot;
  final Set<String> Function() capabilities;
  final FutureOr<void> Function(StudioDocument) applyDocument;
  final VoidCallback? onChanged;

  /// Receives the complete contributed plugin graph. The host preserves base plugins.
  final Future<void> Function(List<ScenePlugin>)? installRuntimePlugins;
  StudioEditorServices({
    required this.scene,
    required this.commands,
    required this.agents,
    this.assets,
    this.viewportController,
    required this.isAvailable,
    required this.viewportSnapshot,
    required this.capabilities,
    required this.applyDocument,
    this.onChanged,
    this.installRuntimePlugins,
  }) {
    if (!identical(scene, commands.scene)) {
      throw ArgumentError('Commands must belong to this scene.');
    }
  }
}

final class StudioEditorContext {
  final StudioEditorHostController _host;
  final _ContributionLease _owner;
  final AttachmentScope scope;
  final StudioAgentExtensionContext _agentContext;
  StudioEditorContext._(
    this._host,
    this._owner,
    this.scope,
    this._agentContext,
  );
  bool get isActive => !_host._closed && !scope.isClosed;
  StudioEditorServices get services => _host.services;
  StudioScene get scene => services.scene;
  StudioCommands get commands => services.commands;
  StudioHistory get history => scene.history;
  String? get selectedId => scene.idFor(scene.tools.selected);
  StudioAssetResolver? get assets => services.assets;
  StudioAssetScope? get assetScope => scene.assets;
  SceneController? get viewportController => services.viewportController;
  Map<String, Object?> get viewport =>
      Map.unmodifiable(services.viewportSnapshot());
  Set<String> get capabilities => Set.unmodifiable(services.capabilities());
  StudioEditorPlaySession? get playSession => _host.activePlaySession;
  bool get isAvailable =>
      isActive && _owner.runtimeReady && services.isAvailable();
  void _check() {
    if (!isActive) throw StateError('Contribution has detached.');
  }

  Future<void> applyDocument(StudioDocument document) {
    _check();
    if (!isAvailable) throw StateError('Editor is unavailable.');
    return Future<void>.sync(() => services.applyDocument(document)).then((_) {
      _host._changed();
    });
  }

  void select(String? id) {
    _check();
    commands.execute(
      commandId: 'editor.${_owner.contribution.id}.${++_host._commandSequence}',
      expectedRevision: commands.revision,
      kind: StudioCommandKind.select,
      targetId: id,
    );
    _host._changed();
  }

  StudioAgentExtensionContext get agentExtensionContext {
    _check();
    if (!_host._mutating && !_owner.runtimeUsed) {
      throw StateError('Declare runtime binding during contribution attach.');
    }
    _owner.runtimeUsed = true;
    return _agentContext;
  }

  void usePlugin(ScenePlugin plugin) {
    _check();
    if (!_host._mutating) {
      throw StateError('Declare scene plugins during contribution attach.');
    }
    _owner.runtimeUsed = true;
    _owner.plugins.add(plugin);
  }

  void useAgentProviderPlugin({
    required String id,
    Set<String> runtimeDependencies = const {},
    required Iterable<AgentProvider> Function(PluginContext) createProviders,
  }) => usePlugin(
    AgentProviderPlugin(
      id: id,
      runtimeDependencies: runtimeDependencies,
      createProviders: createProviders,
    ),
  );

  Registration registerPanel(StudioEditorPanel panel) {
    _check();
    if (_host.reservedPanelIds.contains(panel.id)) {
      throw StateError('Panel ID belongs to the workspace.');
    }
    return _host._register(_host._panels, panel.id, panel, this);
  }

  Registration registerPlacement(StudioEditorPlacement placement) {
    _check();
    return _host._register(_host._placements, placement.id, placement, this);
  }

  Registration registerInspector(StudioEditorInspector inspector) {
    _check();
    return _host._register(_host._inspectors, inspector.id, inspector, this);
  }

  Registration registerAssetKind(StudioEditorAssetKind kind) {
    _check();
    return _host._register(_host._assetKinds, kind.id, kind, this);
  }

  Registration registerCommand(StudioEditorCommand command) {
    _check();
    if (command.shortcut case final shortcut?) {
      final signature = _shortcutSignature(shortcut);
      if (_host._reservedShortcuts.contains(signature) ||
          _host._commands.values.any(
            (entry) =>
                entry.value.shortcut != null &&
                _shortcutSignature(entry.value.shortcut!) == signature,
          )) {
        throw StateError('Keyboard shortcut is already registered.');
      }
    }
    return _host._register(_host._commands, command.id, command, this);
  }

  Registration registerCreationTool(StudioEditorCreationTool tool) {
    _check();
    return _host._register(_host._creationTools, tool.id, tool, this);
  }

  Registration registerOverlay(StudioEditorOverlay overlay) {
    _check();
    return _host._register(_host._overlays, overlay.id, overlay, this);
  }

  Registration registerValidator(StudioEditorValidator validator) {
    _check();
    return _host._register(_host._validators, validator.id, validator, this);
  }

  Registration registerPlayFactory(StudioEditorPlayFactory factory) {
    _check();
    final lease = _host._register(
      _host._playFactories,
      factory.id,
      factory,
      this,
    );
    final combined = Registration(() {
      lease.dispose();
      if (_host._startingFactory == factory.id) {
        ++_host._playEpoch;
        _host._startingFactory = null;
      }
      if (_host._activeFactory == factory.id) {
        _host._trackCleanup(_host.stopPlay());
      }
    });
    scope.keep(combined);
    return combined;
  }
}
