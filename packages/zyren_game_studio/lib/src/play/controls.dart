part of '../../play.dart';

/// Registers one isolated runtime through the existing Studio play host.
final class GamePlayContribution {
  final GameAuthoring authoring;
  final Future<CompiledGameProject> Function(StudioDocument, StudioCancellation)
  compile;
  final SceneRuntime runtime;
  final RendererFactory? fixtureRendererFactory;
  final ModelAssetResolver? modelResolver;
  final ModelManifestResolver? modelManifestResolver;
  final Map<String, MlModelManifest> modelManifests;
  final GamePlayAnimationFactory? animationFactory;
  final SpatialAudio Function(StudioScene)? audioFactory;
  final List<GameSystem> Function(GamePlaySession)? systemFactory;
  final Future<GameRuntimeResourceLease?> Function(GamePlaySession)?
  prepareRuntime;
  final Future<void> Function(StudioEditorContext)? importAssets;
  final Set<String> capabilities;
  final Map<String, Set<String>> editableFields;
  GamePlayContribution({
    required this.authoring,
    required this.compile,
    this.runtime = const SceneRuntime(),
    this.fixtureRendererFactory,
    this.modelResolver,
    this.modelManifestResolver,
    this.modelManifests = const {},
    this.animationFactory,
    this.audioFactory,
    this.systemFactory,
    this.prepareRuntime,
    this.importAssets,
    this.capabilities = const {},
    this.editableFields = const {},
  });
  StudioEditorContribution get contribution => StudioEditorContribution(
    id: 'zyren.game-play',
    version: 1,
    attach: (context) {
      final failure = ValueNotifier<Object?>(null);
      context.scope.onClose(failure.dispose);
      context.registerPlayFactory(
        StudioEditorPlayFactory(
          id: 'game.play',
          label: 'Play game',
          supports: (_, document) =>
              document.extensions.containsKey('zyren.game'),
          create: (context, document) async {
            if (context.isActive) failure.value = null;
            try {
              final revision = context.scene.revision,
                  cancellation = StudioCancellation();
              context.scope.onClose(cancellation.cancel);
              final project = await compile(document, cancellation);
              cancellation.throwIfCancelled();
              if (!context.isAvailable ||
                  context.scene.revision != revision ||
                  context.scene.capture().encode() != document.encode()) {
                throw const StaleApplyBack();
              }
              final session = GamePlaySession(
                authoredScene: context.scene,
                runtime: runtime,
                fixtureRendererFactory: fixtureRendererFactory,
                assetResolver: context.assets,
                modelResolver: modelResolver,
                modelManifestResolver: modelManifestResolver,
                modelManifests: modelManifests,
                animationFactory: animationFactory,
                audioFactory: audioFactory,
                systemFactory: systemFactory,
                prepareRuntime: prepareRuntime,
                capabilities: capabilities,
              );
              try {
                await session.start(project);
                return session;
              } catch (_) {
                await session.stop();
                session.dispose();
                rethrow;
              }
            } catch (error) {
              if (context.isActive) failure.value = error;
              rethrow;
            }
          },
        ),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.runtime',
          title: 'Game play',
          icon: Icons.sports_esports,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, context) => ValueListenableBuilder<Object?>(
            valueListenable: failure,
            builder: (buildContext, error, _) {
              Future<void> retry() async {
                await context.stopPlay();
                await context.startPlay('game.play');
              }

              final session = context.playSession;
              return session is GamePlaySession
                  ? GamePlayView(
                      session: session,
                      onStop: context.stopPlay,
                      onRetry: retry,
                      onImport: importAssets == null
                          ? null
                          : () => importAssets!(context),
                      applyBack: GameApplyBack(
                        scene: context.scene,
                        authoring: authoring,
                        editableFields: editableFields,
                      ),
                    )
                  : ZeroState(
                      title: error == null
                          ? 'Game is stopped'
                          : 'Game play failed',
                      message: error == null
                          ? 'Use Play game to launch an isolated runtime.'
                          : error.toString(),
                      action: Wrap(
                        spacing: 4,
                        children: [
                          TextButton(
                            onPressed: () => _playUiAction(buildContext, retry),
                            child: Text(error == null ? 'Play game' : 'Retry'),
                          ),
                          if (error != null && importAssets != null)
                            TextButton(
                              onPressed: () => _playUiAction(
                                buildContext,
                                () => importAssets!(context),
                              ),
                              child: const Text('Import assets'),
                            ),
                        ],
                      ),
                    );
            },
          ),
        ),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.runtime-inspector',
          title: 'Runtime entity',
          icon: Icons.bug_report,
          defaultDock: StudioEditorDock.right,
          builder: (_, context) {
            final session = context.playSession;
            return session is GamePlaySession
                ? GameRuntimeInspector(session: session)
                : const ZeroState(
                    title: 'No runtime entity',
                    message: 'Launch game play to inspect its entities.',
                  );
          },
        ),
      );
    },
  );
}

void _playUiAction(BuildContext context, Future<void> Function() action) {
  unawaited(() async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }());
}

class GamePlayControls extends StatelessWidget {
  final GamePlaySession session;
  final VoidCallback? onApplyBack;
  final Future<void> Function()? onStop;
  const GamePlayControls({
    super.key,
    required this.session,
    this.onApplyBack,
    this.onStop,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (_, _) => Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Tick ${session.tick} · ${session.state.name}'),
        if (session.simulation != null)
          FilterChip(
            label: const Text('Colliders'),
            selected: session.simulation!.physics.debug,
            onSelected: (enabled) {
              session.simulation!.physics.debug = enabled;
              session.controller?.invalidate();
              session._publish();
            },
          ),
        TextButton.icon(
          onPressed: session.state == GamePlayState.running
              ? session.pause
              : session.isPaused
              ? session.resume
              : null,
          icon: Icon(session.isPaused ? Icons.play_arrow : Icons.pause),
          label: Text(session.isPaused ? 'Resume' : 'Pause'),
        ),
        TextButton.icon(
          onPressed: session.isPaused ? session.step : null,
          icon: const Icon(Icons.skip_next),
          label: const Text('Step'),
        ),
        TextButton.icon(
          onPressed: session.state == GamePlayState.stopped
              ? null
              : () => _playUiAction(context, onStop ?? session.stop),
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
        ),
        if (onApplyBack != null)
          TextButton.icon(
            onPressed: session.isPaused ? onApplyBack : null,
            icon: const Icon(Icons.publish),
            label: const Text('Apply selected fields'),
          ),
      ],
    ),
  );
}

/// Uses the same SceneView and preview resource ownership as Studio animation.
class GamePlayView extends StatefulWidget {
  final GamePlaySession session;
  final GameApplyBack? applyBack;
  final Future<void> Function()? onStop, onRetry, onImport;
  const GamePlayView({
    super.key,
    required this.session,
    this.applyBack,
    this.onStop,
    this.onRetry,
    this.onImport,
  });
  @override
  State<GamePlayView> createState() => _GamePlayViewState();
}

class _GamePlayViewState extends State<GamePlayView> {
  String? _error;
  bool _modal = false;
  Future<void> _apply() async {
    if (_modal) return;
    final source = widget.session.controller?.input;
    final gate = source == null ? null : InputRouter.forSource(source).block();
    setState(() => _modal = true);
    try {
      final apply = widget.applyBack!,
          diff = apply.prepare(
            widget.session.authoredRevision!,
            widget.session.snapshot(),
          ),
          selected = diff.fields.map((f) => f.id).toSet();
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Apply runtime fields'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final field in diff.fields)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${field.nodeId}: ${field.path}'),
                        subtitle: Text('${field.before} → ${field.after}'),
                        value: selected.contains(field.id),
                        onChanged: (v) => update(() {
                          if (v == true) {
                            selected.add(field.id);
                          } else {
                            selected.remove(field.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Apply selected'),
              ),
            ],
          ),
        ),
      );
      if (accepted != true) return;
      final revision = widget.session.authoredRevision!;
      await (widget.onStop ?? widget.session.stop)();
      apply.commit(diff, expectedRevision: revision, selectedFields: selected);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      gate?.dispose();
      if (mounted) setState(() => _modal = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (_, _) {
      final controller = widget.session.controller;
      return Column(
        children: [
          GamePlayControls(
            session: widget.session,
            onStop: widget.onStop,
            onApplyBack: widget.applyBack == null
                ? null
                : () => unawaited(_apply()),
          ),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Expanded(
            child: widget.session.error != null
                ? ZeroState(
                    title: 'Game play failed',
                    message: widget.session.error.toString(),
                    action: Wrap(
                      spacing: 4,
                      children: [
                        if (widget.onRetry != null)
                          TextButton(
                            onPressed: () =>
                                _playUiAction(context, widget.onRetry!),
                            child: const Text('Retry'),
                          ),
                        if (widget.onImport != null)
                          TextButton(
                            onPressed: () =>
                                _playUiAction(context, widget.onImport!),
                            child: const Text('Import assets'),
                          ),
                      ],
                    ),
                  )
                : controller == null
                ? const ZeroState(
                    title: 'Game is stopped',
                    message: 'Launch another play session to continue.',
                  )
                : GamePlayInput(
                    actions: widget.session.actions,
                    source: controller.input,
                    enabled:
                        !_modal &&
                        widget.session.state == GamePlayState.running,
                    child: SceneView(controller: controller),
                  ),
          ),
        ],
      );
    },
  );
}

/// Holds the viewport's real focus across action-state initialization.
class GamePlayInput extends StatefulWidget {
  final GameActionState? actions;
  final InputSource source;
  final bool enabled;
  final Widget child;
  const GamePlayInput({
    super.key,
    required this.actions,
    required this.source,
    required this.enabled,
    required this.child,
  });
  @override
  State<GamePlayInput> createState() => _GamePlayInputState();
}

class _GamePlayInputState extends State<GamePlayInput> {
  final _focus = FocusNode(debugLabel: 'game.play.viewport');
  GameInputAdapter? _input;
  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(GamePlayInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.actions, oldWidget.actions) ||
        !identical(widget.source, oldWidget.source)) {
      _sync();
    }
    _input?.setEnabled(widget.enabled);
  }

  void _sync() {
    _input?.dispose();
    final actions = widget.actions;
    _input = actions == null
        ? null
        : (GameInputAdapter(actions: actions, source: widget.source)
            ..setFocus(_focus.hasFocus)
            ..setEnabled(widget.enabled));
  }

  @override
  void dispose() {
    _input?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onFocusChange: (v) => _input?.setFocus(v),
    onKeyEvent: (_, event) => _input?.key(event) ?? KeyEventResult.ignored,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _focus.requestFocus(),
      child: widget.child,
    ),
  );
}
