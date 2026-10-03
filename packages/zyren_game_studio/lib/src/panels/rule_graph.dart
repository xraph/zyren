part of '../../zyren_game_studio.dart';

class GameRuleGraphPanel extends StatefulWidget {
  final StudioEditorContext context;
  final GameAuthoring authoring;
  final GameRuleLibrary rules;
  final String? state;
  const GameRuleGraphPanel({
    super.key,
    required this.context,
    required this.authoring,
    required this.rules,
    this.state,
  });
  @override
  State<GameRuleGraphPanel> createState() => _GameRuleGraphPanelState();
}

class _GameRuleGraphPanelState extends State<GameRuleGraphPanel> {
  String? error;
  bool busy = false;
  GameRuleAuthoring get edits =>
      GameRuleAuthoring(widget.authoring, widget.rules, state: widget.state);
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

  Future<void> add(String actorNode, GameRuleGraph graph) async {
    final parents = graph.nodes
        .where(
          (n) =>
              n.kind == GameRuleKind.sequence ||
              n.kind == GameRuleKind.selector,
        )
        .toList();
    if (parents.isEmpty) return;
    var parent = parents.first.id, kind = GameRuleKind.action;
    var operation = widget.rules.actions.ports.keys.first;
    var arguments = <String, Object?>{};
    void defaults() {
      if (kind != GameRuleKind.action && kind != GameRuleKind.predicate) {
        arguments = {};
        return;
      }
      final ports = (kind == GameRuleKind.action
          ? widget.rules.actions.ports
          : widget.rules.predicates.ports)[operation]!;
      arguments = {
        for (final p in ports.entries)
          p.key: switch (p.value) {
            GamePortType.boolean => false,
            GamePortType.integer => 1,
            GamePortType.number => 1.0,
            GamePortType.string =>
              p.key == 'target' || p.key == 'source'
                  ? widget.authoring
                        .editableEntities(widget.context.scene.document)
                        .first
                        .id
                  : 'key',
          },
      };
    }

    defaults();
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Add rule node'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: parent,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Parent'),
                      items: [
                        for (final n in parents)
                          DropdownMenuItem(value: n.id, child: Text(n.id)),
                      ],
                      onChanged: (v) => update(() => parent = v!),
                    ),
                    DropdownButtonFormField<GameRuleKind>(
                      initialValue: kind,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Kind'),
                      items: [
                        for (final k in [
                          GameRuleKind.action,
                          GameRuleKind.predicate,
                          GameRuleKind.sequence,
                          GameRuleKind.selector,
                        ])
                          DropdownMenuItem(value: k, child: Text(k.name)),
                      ],
                      onChanged: (v) => update(() {
                        kind = v!;
                        operation =
                            (kind == GameRuleKind.action
                                    ? widget.rules.actions.ports
                                    : widget.rules.predicates.ports)
                                .keys
                                .first;
                        defaults();
                      }),
                    ),
                    if (kind == GameRuleKind.action ||
                        kind == GameRuleKind.predicate)
                      DropdownButtonFormField<String>(
                        key: ValueKey(kind),
                        initialValue: operation,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Registered operation',
                        ),
                        items: [
                          for (final id
                              in (kind == GameRuleKind.action
                                      ? widget.rules.actions.ports
                                      : widget.rules.predicates.ports)
                                  .keys)
                            DropdownMenuItem(value: id, child: Text(id)),
                        ],
                        onChanged: (v) => update(() {
                          operation = v!;
                          defaults();
                        }),
                      ),
                    for (final entry in arguments.entries)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child:
                            entry.key == 'target' ||
                                entry.key == 'source' ||
                                entry.value is bool
                            ? GameComponentField(
                                key: ValueKey('$operation/${entry.key}'),
                                descriptor: _port(entry.key, entry.value),
                                value: entry.value,
                                origin: GameFieldOrigin.authored,
                                entities: widget.authoring.editableEntities(
                                  widget.context.scene.document,
                                ),
                                enabled: true,
                                onChanged: (v) =>
                                    update(() => arguments[entry.key] = v),
                              )
                            : TextFormField(
                                key: ValueKey('$operation/${entry.key}'),
                                initialValue: '${entry.value}',
                                decoration: InputDecoration(
                                  labelText: entry.key,
                                  isDense: true,
                                ),
                                validator: (text) =>
                                    _port(entry.key, entry.value).validate(
                                      entry.value is int
                                          ? int.tryParse(text ?? '')
                                          : entry.value is num
                                          ? double.tryParse(text ?? '')
                                          : text,
                                    ),
                                onSaved: (text) =>
                                    arguments[entry.key] = entry.value is int
                                    ? int.parse(text!)
                                    : entry.value is num
                                    ? double.parse(text!)
                                    : text!,
                              ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                form.currentState!.save();
                Navigator.pop(context, true);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    var suffix = 1;
    while (graph.nodes.any((n) => n.id == 'node-$suffix')) {
      suffix++;
    }
    await edit(
      (d) => edits.appendChild(
        d,
        actorNode,
        parent,
        GameRuleNode(
          id: 'node-$suffix',
          kind: kind,
          operation:
              kind == GameRuleKind.action || kind == GameRuleKind.predicate
              ? operation
              : null,
          arguments: arguments,
        ),
      ),
    );
  }

  GameFieldDescriptor _port(String name, Object? value) => GameFieldDescriptor(
    name,
    name,
    name == 'target' || name == 'source'
        ? GameFieldKind.entity
        : value is bool
        ? GameFieldKind.boolean
        : value is int
        ? GameFieldKind.integer
        : value is num
        ? GameFieldKind.number
        : GameFieldKind.text,
  );
  @override
  Widget build(BuildContext context) {
    final nodeId = widget.context.selectedId,
        document = widget.context.scene.document;
    if (nodeId == null) {
      return const ZeroState(
        title: 'Select an entity',
        message: 'Select an entity to author its behavior rules.',
      );
    }
    final record = widget.authoring
        .entityFor(document, nodeId)
        ?.components
        .where(
          (c) =>
              c.type ==
              (widget.state == null ? 'game.rules' : 'game.state-machine'),
        )
        .firstOrNull;
    if (record == null) {
      return ZeroState(
        title: 'No behavior graph',
        message: 'Add a graph using registered game actions and predicates.',
        actionLabel: 'Add graph',
        onAction: () => edit(
          (d) => edits.replace(
            d,
            nodeId,
            GameRuleDefinition(
              graph: GameRuleGraph(
                root: 'root',
                nodes: [GameRuleNode.sequence('root', [])],
              ),
            ),
          ),
        ),
      );
    }
    GameRuleDefinition definition;
    try {
      definition = edits.read(document, nodeId);
      definition.graph.compile(widget.rules.actions, widget.rules.predicates);
    } catch (e) {
      return ZeroState(
        title: 'Behavior graph needs repair',
        message: 'Repair the component in the inspector, then recheck. $e',
        actionLabel: 'Recheck',
        onAction: () => setState(() {}),
      );
    }
    final enabled = !busy && widget.context.isAvailable;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Row(
          children: [
            Expanded(child: Text('Root: ${definition.graph.root}')),
            TextButton.icon(
              onPressed: enabled ? () => add(nodeId, definition.graph) : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add node'),
            ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Repeat graph'),
          value: definition.repeat,
          onChanged: enabled
              ? (v) => edit(
                  (d) => edits.replace(
                    d,
                    nodeId,
                    GameRuleDefinition(graph: definition.graph, repeat: v),
                  ),
                )
              : null,
        ),
        for (final node in definition.graph.nodes)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text(node.id),
            subtitle: Text(
              '${node.operation ?? node.kind.name}${node.children.isEmpty ? '' : ' → ${node.children.join(', ')}'}',
            ),
            trailing: node.id == definition.graph.root
                ? null
                : IconButton(
                    tooltip: 'Remove ${node.id} subtree',
                    icon: const Icon(Icons.remove_circle_outline, size: 18),
                    onPressed: enabled
                        ? () => edit(
                            (d) => edits.removeSubtree(d, nodeId, node.id),
                          )
                        : null,
                  ),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: enabled
                      ? () => edit((d) => edits.invert(d, nodeId, node.id))
                      : null,
                  child: Text(
                    node.kind == GameRuleKind.inverter
                        ? 'Remove inversion'
                        : 'Invert result',
                  ),
                ),
              ),
              for (var i = 0; i < node.children.length; i++)
                Row(
                  children: [
                    Expanded(child: Text('${i + 1}. ${node.children[i]}')),
                    IconButton(
                      tooltip: 'Move ${node.children[i]} earlier',
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      onPressed: enabled && i > 0
                          ? () => edit(
                              (d) =>
                                  edits.moveChild(d, nodeId, node.id, i, i - 1),
                            )
                          : null,
                    ),
                    IconButton(
                      tooltip: 'Move ${node.children[i]} later',
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      onPressed: enabled && i + 1 < node.children.length
                          ? () => edit(
                              (d) =>
                                  edits.moveChild(d, nodeId, node.id, i, i + 1),
                            )
                          : null,
                    ),
                  ],
                ),
              for (final argument in node.arguments.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: GameComponentField(
                    key: ValueKey(
                      '${node.id}/${argument.key}/${argument.value}',
                    ),
                    descriptor: _port(argument.key, argument.value),
                    value: argument.value,
                    origin: GameFieldOrigin.authored,
                    entities: widget.authoring.editableEntities(document),
                    enabled: enabled,
                    onChanged: (value) => edit(
                      (d) => edits.replaceNode(
                        d,
                        nodeId,
                        GameRuleNode(
                          id: node.id,
                          kind: node.kind,
                          operation: node.operation,
                          children: node.children,
                          arguments: {...node.arguments, argument.key: value},
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
