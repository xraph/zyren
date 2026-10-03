part of '../../zyren_game_studio.dart';

final class GameLevelStudioContribution {
  final GameAuthoring authoring;
  final GameRuleLibrary rules;
  GameLevelStudioContribution(this.authoring, this.rules);
  StudioEditorContribution get contribution => StudioEditorContribution(
    id: 'zyren.game-levels',
    version: 1,
    dependencies: {'zyren.game-editor'},
    attach: (context) {
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.states',
          title: 'State machines',
          icon: Icons.hub_outlined,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, c) => GameStateMachinePanel(
            context: c,
            authoring: authoring,
            rules: rules,
          ),
        ),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.level',
          title: 'Level tools',
          icon: Icons.map_outlined,
          defaultDock: StudioEditorDock.rightLower,
          builder: (_, c) => GameLevelTools(context: c, authoring: authoring),
        ),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.rules',
          title: 'Game rules',
          icon: Icons.account_tree_outlined,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, c) => GameRuleGraphPanel(
            context: c,
            authoring: authoring,
            rules: rules,
          ),
        ),
      );
    },
  );
}

class GameLevelTools extends StatefulWidget {
  final StudioEditorContext context;
  final GameAuthoring authoring;
  const GameLevelTools({
    super.key,
    required this.context,
    required this.authoring,
  });
  @override
  State<GameLevelTools> createState() => _GameLevelToolsState();
}

class _GameLevelToolsState extends State<GameLevelTools> {
  String? error;
  bool busy = false;
  GameLevelAuthoring get edits => GameLevelAuthoring(widget.authoring);
  Future<void> edit(StudioDocument Function(StudioDocument) operation) async {
    if (busy || !widget.context.isAvailable) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.context.applyDocument(
        operation(widget.context.scene.document),
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void bake() => edit((document) {
    final hash = GameLevelAuthoring.geometryHash(document);
    final sources = <NavigationGeometry>[];
    for (final entity in widget.authoring.expanded(document).entities) {
      final record = entity.components
          .where((c) => c.type == 'game.collider')
          .firstOrNull;
      if (record == null ||
          GameColliderDefinition.fromJson(record.data).motion !=
              GameBodyMotion.fixed) {
        continue;
      }
      final object = widget.context.scene.objects[entity.nodeId];
      var part = 0;
      final pending = [?object];
      while (pending.isNotEmpty) {
        final object = pending.removeLast();
        pending.addAll(object.children);
        if (object is Mesh) {
          sources.add(
            NavigationGeometry.fromMesh(
              object,
              sourceId: '${entity.id}/${part++}',
              revision: hash,
            ),
          );
        }
      }
    }
    return edits.saveNavigation(
      document,
      edits.bakeNavigation(
        document,
        sources,
        settings: NavigationBakeSettings(cellSize: .3),
      ),
    );
  });
  @override
  Widget build(BuildContext context) {
    final document = widget.context.scene.document;
    GameBuildProfile profile;
    Map<String, Object?> settings;
    try {
      profile = edits.profile(document);
      settings = edits.settings(document);
    } catch (e) {
      return ZeroState(title: 'Level settings need repair', message: '$e');
    }
    final nav = settings['navigation'] as Map?;
    final current =
        nav != null &&
        nav['documentGeometryHash'] ==
            GameLevelAuthoring.geometryHash(document);
    final enabled = !busy && widget.context.isAvailable;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Text('Build profile', style: Theme.of(context).textTheme.titleSmall),
        Row(
          children: [
            Expanded(
              child: GameComponentField(
                descriptor: const GameFieldDescriptor(
                  'id',
                  'Name',
                  GameFieldKind.text,
                ),
                value: profile.id,
                origin: GameFieldOrigin.authored,
                entities: const [],
                enabled: enabled,
                onChanged: (v) => edit(
                  (d) => edits.setProfile(
                    d,
                    GameBuildProfile(
                      id: v as String,
                      fixedHz: profile.fixedHz,
                      capabilities: profile.capabilities,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GameComponentField(
                descriptor: const GameFieldDescriptor(
                  'fixedHz',
                  'Tick rate',
                  GameFieldKind.integer,
                  minimum: 10,
                  maximum: 240,
                  unit: 'Hz',
                ),
                value: profile.fixedHz,
                origin: GameFieldOrigin.authored,
                entities: const [],
                enabled: enabled,
                onChanged: (v) => edit(
                  (d) => edits.setProfile(
                    d,
                    GameBuildProfile(
                      id: profile.id,
                      fixedHz: v as int,
                      capabilities: profile.capabilities,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              nav == null
                  ? 'No navigation bake'
                  : current
                  ? 'Navigation source unchanged'
                  : 'Navigation stale',
            ),
            TextButton.icon(
              onPressed: enabled ? bake : null,
              icon: const Icon(Icons.route, size: 16),
              label: const Text('Bake navigation'),
            ),
          ],
        ),
        const Divider(height: 16),
        Text('Templates', style: Theme.of(context).textTheme.titleSmall),
        const Text(
          'Replace the scene in one undoable edit. Templates include their primitive assets.',
        ),
        for (final kind in GameTemplateKind.values)
          TextButton.icon(
            onPressed: enabled
                ? () => edit(
                    (d) => GameTemplate(
                      kind,
                      widget.authoring,
                    ).create(projectId: d.id, documentId: d.id).document,
                  )
                : null,
            icon: Icon(
              kind == GameTemplateKind.exploration
                  ? Icons.directions_walk
                  : Icons.directions_car,
            ),
            label: Text(
              kind == GameTemplateKind.exploration
                  ? 'Use exploration template'
                  : 'Use vehicle playground',
            ),
          ),
      ],
    );
  }
}
