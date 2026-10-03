part of '../../zyren_game_studio.dart';

class GameStateMachinePanel extends StatefulWidget {
  final StudioEditorContext context;
  final GameAuthoring authoring;
  final GameRuleLibrary rules;
  const GameStateMachinePanel({
    super.key,
    required this.context,
    required this.authoring,
    required this.rules,
  });
  @override
  State<GameStateMachinePanel> createState() => _GameStateMachinePanelState();
}

class _GameStateMachinePanelState extends State<GameStateMachinePanel> {
  String? selected, error;
  bool busy = false;
  GameStateMachineAuthoring get edits =>
      GameStateMachineAuthoring(widget.authoring, widget.rules);
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
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addState(String nodeId) async {
    String name = '';
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add state'),
        content: Form(
          key: form,
          child: TextFormField(
            autofocus: true,
            decoration: const InputDecoration(labelText: 'State ID'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Enter a state ID.'
                : null,
            onSaved: (value) => name = value!.trim(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                form.currentState!.save();
                Navigator.pop(context, true);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await edit((d) => edits.addState(d, nodeId, name));
      if (mounted && error == null) setState(() => selected = name);
    }
  }

  Future<void> addTransition(
    String nodeId,
    GameStateMachineDefinition machine,
  ) async {
    var from = machine.states.containsKey(selected)
            ? selected!
            : machine.initial,
        to = machine.initial;
    var predicate = widget.rules.predicates.ports.keys.first;
    var arguments = <String, Object?>{};
    void defaults() {
      arguments = {
        for (final port in widget.rules.predicates.ports[predicate]!.entries)
          port.key: switch (port.value) {
            GamePortType.boolean => false,
            GamePortType.integer => 1,
            GamePortType.number => 1.0,
            GamePortType.string => 'key',
          },
      };
    }

    defaults();
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Add transition'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final field in ['From', 'To'])
                      DropdownButtonFormField<String>(
                        initialValue: field == 'From' ? from : to,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: field),
                        items: [
                          for (final id in machine.states.keys)
                            DropdownMenuItem(value: id, child: Text(id)),
                        ],
                        onChanged: (v) => update(() {
                          if (field == 'From') {
                            from = v!;
                          } else {
                            to = v!;
                          }
                        }),
                      ),
                    DropdownButtonFormField<String>(
                      initialValue: predicate,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Guard'),
                      items: [
                        for (final id in widget.rules.predicates.ports.keys)
                          DropdownMenuItem(value: id, child: Text(id)),
                      ],
                      onChanged: (v) => update(() {
                        predicate = v!;
                        defaults();
                      }),
                    ),
                    for (final arg in arguments.entries)
                      if (arg.value is bool)
                        SwitchListTile(
                          dense: true,
                          title: Text(arg.key),
                          value: arg.value as bool,
                          onChanged: (v) =>
                              update(() => arguments[arg.key] = v),
                        )
                      else
                        TextFormField(
                          key: ValueKey('$predicate/${arg.key}'),
                          initialValue: '${arg.value}',
                          decoration: InputDecoration(labelText: arg.key),
                          validator: (v) => arg.value is int
                              ? (int.tryParse(v ?? '') == null
                                    ? 'Enter an integer.'
                                    : null)
                              : arg.value is num &&
                                    (double.tryParse(v ?? '')?.isFinite != true)
                              ? 'Enter a finite number.'
                              : null,
                          onSaved: (v) => arguments[arg.key] = arg.value is int
                              ? int.parse(v!)
                              : arg.value is num
                              ? double.parse(v!)
                              : v!,
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
                if (form.currentState!.validate()) {
                  form.currentState!.save();
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) {
      await edit((d) {
        final current = edits.read(d, nodeId);
        return edits.replace(
          d,
          nodeId,
          GameStateMachineDefinition(
            initial: current.initial,
            states: current.states,
            transitions: [
              ...current.transitions,
              GameStateTransition(
                from: from,
                to: to,
                predicate: predicate,
                arguments: arguments,
              ),
            ],
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final nodeId = widget.context.selectedId,
        document = widget.context.scene.document;
    if (nodeId == null) {
      return const ZeroState(
        title: 'Select an entity',
        message: 'Select an entity to edit its states.',
      );
    }
    final record = widget.authoring
        .entityFor(document, nodeId)
        ?.components
        .where((c) => c.type == 'game.state-machine')
        .firstOrNull;
    if (record == null) {
      return ZeroState(
        title: 'No state machine',
        message:
            'States use the same registered actions and predicates as behavior graphs.',
        actionLabel: 'Add state machine',
        onAction: () => edit(
          (d) => edits.replace(
            d,
            nodeId,
            GameStateMachineDefinition(
              initial: 'idle',
              states: {
                'idle': GameRuleDefinition(
                  graph: GameRuleGraph(
                    root: 'root',
                    nodes: [GameRuleNode.sequence('root', [])],
                  ),
                ),
              },
              transitions: [],
            ),
          ),
        ),
      );
    }
    GameStateMachineDefinition machine;
    try {
      machine = GameStateMachineDefinition.fromJson(record.data);
      machine.validate(widget.rules.actions, widget.rules.predicates);
    } catch (e) {
      return ZeroState(
        title: 'State machine needs repair',
        message: 'Repair the component in the inspector, then recheck. $e',
        actionLabel: 'Recheck',
        onAction: () => setState(() {}),
      );
    }
    final state = machine.states.containsKey(selected)
        ? selected!
        : machine.initial;
    final enabled = !busy && widget.context.isAvailable;
    return Column(
      children: [
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('$nodeId/$state'),
                  initialValue: state,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'State',
                    isDense: true,
                  ),
                  items: [
                    for (final id in machine.states.keys)
                      DropdownMenuItem(
                        value: id,
                        child: Text(
                          id == machine.initial ? '$id (initial)' : id,
                        ),
                      ),
                  ],
                  onChanged: enabled
                      ? (v) => setState(() => selected = v)
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Add state',
                onPressed: enabled ? () => addState(nodeId) : null,
                icon: const Icon(Icons.add),
              ),
              IconButton(
                tooltip: 'Remove state',
                onPressed: enabled && state != machine.initial
                    ? () => edit((d) => edits.removeState(d, nodeId, state))
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: enabled && state != machine.initial
                  ? () => edit(
                      (d) => edits.replace(
                        d,
                        nodeId,
                        GameStateMachineDefinition(
                          initial: state,
                          states: machine.states,
                          transitions: machine.transitions,
                        ),
                      ),
                    )
                  : null,
              child: const Text('Set initial'),
            ),
            TextButton.icon(
              onPressed: enabled ? () => addTransition(nodeId, machine) : null,
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text('Add transition'),
            ),
          ],
        ),
        if (machine.transitions.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (var i = 0; i < machine.transitions.length; i++)
                  ListTile(
                    dense: true,
                    title: Text(
                      '${machine.transitions[i].from} → ${machine.transitions[i].to}',
                    ),
                    subtitle: Text(
                      '${machine.transitions[i].predicate} ${machine.transitions[i].arguments}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Remove transition ${i + 1}',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: enabled
                          ? () => edit(
                              (d) => edits.replace(
                                d,
                                nodeId,
                                GameStateMachineDefinition(
                                  initial: machine.initial,
                                  states: machine.states,
                                  transitions: [...machine.transitions]
                                    ..removeAt(i),
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: GameRuleGraphPanel(
            key: ValueKey('$nodeId/$state'),
            context: widget.context,
            authoring: widget.authoring,
            rules: widget.rules,
            state: state,
          ),
        ),
      ],
    );
  }
}
