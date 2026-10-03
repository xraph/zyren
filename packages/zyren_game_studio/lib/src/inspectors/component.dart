part of '../../zyren_game_studio.dart';

/// Each accepted field edit enters the host's existing immutable document history.
class GameComponentInspector extends StatefulWidget {
  final StudioEditorContext context;
  final GameAuthoring authoring;
  const GameComponentInspector({
    super.key,
    required this.context,
    required this.authoring,
  });
  @override
  State<GameComponentInspector> createState() => _GameComponentInspectorState();
}

class _GameComponentInspectorState extends State<GameComponentInspector> {
  String? _error;
  bool _busy = false;
  Future<void> _edit(StudioDocument Function(StudioDocument) edit) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.context.applyDocument(edit(widget.context.scene.document));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.context.scene.document,
        nodeId = widget.context.selectedId;
    if (nodeId == null) {
      return const ZeroState(
        title: 'Select an entity',
        message: 'Select a scene object to edit its game components.',
      );
    }
    GameEntityRecord? entity;
    try {
      entity = widget.authoring.entityFor(document, nodeId);
    } catch (error) {
      return ZeroState(
        title: 'Components need repair',
        message: error.toString(),
      );
    }
    final types = entity?.components.map((c) => c.type).toSet() ?? <String>{};
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              _error!,
              semanticsLabel: 'Game edit failed: $_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            if (!document.prefabOwners.containsKey(nodeId))
              PopupMenuButton<String>(
                tooltip: 'Add game component',
                enabled: !_busy && widget.context.isAvailable,
                onSelected: (type) => _edit(
                  (d) => widget.authoring.addComponent(
                    d,
                    nodeId,
                    widget.authoring.descriptors[type]!.create(),
                  ),
                ),
                itemBuilder: (_) => [
                  for (final descriptor
                      in widget.authoring.descriptors.values.where(
                        (d) => !types.contains(d.type),
                      ))
                    PopupMenuItem(
                      value: descriptor.type,
                      child: Text(descriptor.label),
                    ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                  child: Text('Add component'),
                ),
              ),
            if (entity != null && !document.prefabOwners.containsKey(nodeId))
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _edit(
                        (d) => widget.authoring.duplicate(
                          d,
                          nodeId,
                          newId: _nextId(d, '$nodeId-copy'),
                        ),
                      ),
                child: const Text('Duplicate'),
              ),
            if (entity != null &&
                document.expandedNodes[nodeId]!.kind != StudioNodeKind.prefab &&
                !document.prefabOwners.containsKey(nodeId))
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _edit(
                        (d) => widget.authoring.createPrefab(
                          d,
                          nodeId,
                          prefabId: _nextPrefabId(d, nodeId),
                        ),
                      ),
                child: const Text('Make prefab'),
              ),
          ],
        ),
        if (entity == null || entity.components.isEmpty)
          const ZeroState(
            title: 'No game components',
            message: 'Use Add component to define this object’s game behavior.',
          ),
        for (final component in entity?.components ?? <GameComponentRecord>[])
          _component(document, nodeId, component),
      ],
    );
  }

  Widget _component(
    StudioDocument document,
    String nodeId,
    GameComponentRecord component,
  ) {
    final descriptor = widget.authoring.descriptors[component.type];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                descriptor?.label ?? component.type,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (!document.prefabOwners.containsKey(nodeId))
              IconButton(
                tooltip: 'Remove ${descriptor?.label ?? component.type}',
                icon: const Icon(Icons.remove_circle_outline, size: 18),
                onPressed: _busy
                    ? null
                    : () => _edit(
                        (d) => widget.authoring.removeComponent(
                          d,
                          nodeId: nodeId,
                          component: component.type,
                        ),
                      ),
              ),
          ],
        ),
        if (descriptor == null)
          const Text('Load this component’s editor to change its fields.'),
        for (final field in descriptor?.fields ?? <GameFieldDescriptor>[])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: GameComponentField(
              key: ValueKey(
                '$nodeId/${component.type}/${field.name}/${jsonEncode(component.data[field.name])}',
              ),
              descriptor: field,
              value: component.data[field.name],
              origin: widget.authoring.fieldOrigin(
                document,
                nodeId: nodeId,
                component: component.type,
                field: field.name,
              ),
              entities: widget.authoring.editableEntities(document),
              enabled: !_busy && widget.context.isAvailable,
              onChanged: (value) => _edit(
                (d) => widget.authoring.setField(
                  d,
                  nodeId: nodeId,
                  component: component.type,
                  field: field.name,
                  value: value,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _nextId(StudioDocument document, String base) {
  var id = base, index = 2;
  while (document.expandedNodes.containsKey(id)) {
    id = '$base-${index++}';
  }
  return id;
}

String _nextPrefabId(StudioDocument document, String base) {
  var id = base, index = 2;
  while (document.prefabs.any((p) => p.id == id)) {
    id = '$base-${index++}';
  }
  return id;
}

class GameComponentField extends StatelessWidget {
  final GameFieldDescriptor descriptor;
  final Object? value;
  final GameFieldOrigin origin;
  final List<GameEntityRecord> entities;
  final bool enabled;
  final ValueChanged<Object?> onChanged;
  const GameComponentField({
    super.key,
    required this.descriptor,
    required this.value,
    required this.origin,
    required this.entities,
    required this.enabled,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final label =
        '${descriptor.label}${descriptor.unit.isEmpty ? "" : " (${descriptor.unit})"}';
    final decoration = InputDecoration(
      labelText: label,
      helperText: origin == GameFieldOrigin.authored ? null : origin.name,
      isDense: true,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.all(8),
    );
    switch (descriptor.kind) {
      case GameFieldKind.boolean:
        return SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          subtitle: origin == GameFieldOrigin.authored
              ? null
              : Text(origin.name),
          value: value == true,
          onChanged: enabled ? onChanged : null,
        );
      case GameFieldKind.choice:
      case GameFieldKind.entity:
        final choices = descriptor.kind == GameFieldKind.entity
            ? entities.map((e) => e.id).toList()
            : descriptor.choices;
        return DropdownButtonFormField<String>(
          isExpanded: true,
          decoration: descriptor.required
              ? decoration
              : decoration.copyWith(
                  suffixIcon: IconButton(
                    tooltip: 'Clear ${descriptor.label}',
                    onPressed: enabled && value != null
                        ? () => onChanged(null)
                        : null,
                    icon: const Icon(Icons.clear, size: 18),
                  ),
                ),
          initialValue: choices.contains(value) ? value as String : null,
          items: choices
              .map(
                (v) => DropdownMenuItem(
                  value: v,
                  child: Text(v, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: enabled ? onChanged : null,
        );
      case GameFieldKind.vector:
        final values = value is List && (value as List).length == 3
            ? value as List
            : [0, 0, 0];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label · ${origin.name}'),
            Row(
              children: [
                for (var axis = 0; axis < 3; axis++)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: axis == 2 ? 0 : 4),
                      child: TextFormField(
                        initialValue: '${values[axis]}',
                        enabled: enabled,
                        decoration: InputDecoration(
                          labelText: ['X', 'Y', 'Z'][axis],
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        onFieldSubmitted: (text) {
                          final number = double.tryParse(text);
                          if (number != null && number.isFinite) {
                            final next = [...values];
                            next[axis] = number;
                            onChanged(next);
                          }
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      case GameFieldKind.json:
        return _GameStructuredField(
          label: label,
          origin: origin,
          entryTemplate: descriptor.entryTemplate,
          entryBatchSize: descriptor.entryBatchSize,
          value: value,
          enabled: enabled,
          onChanged: onChanged,
        );
      case GameFieldKind.integer:
      case GameFieldKind.number:
      case GameFieldKind.text:
        return TextFormField(
          initialValue: value?.toString() ?? '',
          decoration: decoration,
          enabled: enabled,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (text) => descriptor.validate(_parse(text ?? '')),
          keyboardType: descriptor.kind == GameFieldKind.text
              ? TextInputType.text
              : const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
          onFieldSubmitted: (text) {
            final parsed = _parse(text);
            if (descriptor.validate(parsed) == null) onChanged(parsed);
          },
        );
    }
  }

  Object? _parse(String text) => switch (descriptor.kind) {
    GameFieldKind.text when !descriptor.required && text.trim().isEmpty => null,
    GameFieldKind.integer => int.tryParse(text),
    GameFieldKind.number => double.tryParse(text),
    _ => text,
  };
}

class _GameStructuredField extends StatelessWidget {
  final String label;
  final GameFieldOrigin origin;
  final Object? value;
  final bool enabled;
  final Map<String, Object?>? entryTemplate;
  final int entryBatchSize;
  final ValueChanged<Object?> onChanged;
  const _GameStructuredField({
    required this.label,
    required this.origin,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.entryTemplate,
    this.entryBatchSize = 1,
  });
  Future<void> _add(BuildContext context) async {
    final map = value is Map;
    final draft = <String, Object?>{
      ...?(map ? <String, Object?>{'name': 'item', 'count': 1} : entryTemplate),
    };
    if (draft.isEmpty) return;
    final form = GlobalKey<FormState>();
    final next = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            entryBatchSize == 2 ? 'Add wheel pair' : 'Add $label entry',
          ),
          content: SizedBox(
            width: 340,
            child: Form(
              key: form,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in draft.entries.toList())
                      if (entry.value is bool)
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(entry.key),
                          value: entry.value == true,
                          onChanged: (v) => update(() => draft[entry.key] = v),
                        )
                      else if (entry.value is List &&
                          (entry.value as List).length == 3 &&
                          (entry.value as List).every((v) => v is num))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              for (var axis = 0; axis < 3; axis++)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: TextFormField(
                                      initialValue:
                                          '${(entry.value as List)[axis]}',
                                      decoration: InputDecoration(
                                        labelText:
                                            '${entry.key} ${['X', 'Y', 'Z'][axis]}',
                                        isDense: true,
                                        border: const OutlineInputBorder(),
                                      ),
                                      validator: (text) =>
                                          double.tryParse(
                                                text ?? '',
                                              )?.isFinite ==
                                              true
                                          ? null
                                          : 'Enter a finite number.',
                                      onSaved: (text) {
                                        final coordinates = List<Object?>.from(
                                          draft[entry.key] as List,
                                        );
                                        coordinates[axis] = double.parse(text!);
                                        draft[entry.key] = coordinates;
                                      },
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        )
                      else if (entry.value is String || entry.value is num)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: TextFormField(
                            initialValue: entry.value.toString(),
                            decoration: InputDecoration(
                              labelText: entry.key,
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                            validator: (text) =>
                                text == null ||
                                    text.trim().isEmpty ||
                                    (entry.value is int
                                        ? int.tryParse(text) == null
                                        : entry.value is num &&
                                              double.tryParse(text)?.isFinite !=
                                                  true)
                                ? 'Enter a valid ${entry.key}.'
                                : null,
                            onSaved: (text) =>
                                draft[entry.key] = entry.value is int
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
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  form.currentState!.save();
                  Navigator.pop(context, draft);
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (next == null) return;
    if (map) {
      final entries = Map<String, Object?>.from(value as Map);
      final name = next['name'] as String;
      if (entries.containsKey(name)) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('That entry already exists.')),
          );
        }
        return;
      }
      entries[name] = next['count'];
      onChanged(entries);
    } else {
      final entries = [...value as List];
      final id = next['id'] as String?;
      if (entryBatchSize == 2 && id != null && next['mount'] is List) {
        final mount = List<Object?>.from(next['mount'] as List);
        entries.add({
          ...next,
          'id': '$id-left',
          'mount': [-(mount[0] as num).abs(), mount[1], mount[2]],
        });
        entries.add({
          ...next,
          'id': '$id-right',
          'mount': [(mount[0] as num).abs(), mount[1], mount[2]],
        });
      } else {
        entries.add(next);
      }
      onChanged(entries);
    }
  }

  void _remove(int index) {
    final entries = [...value as List];
    if (entryBatchSize == 2) {
      final selected = entries[index] as Map;
      final mount = selected['mount'] as List;
      final id = selected['id'] as String;
      final pairedId = id.endsWith('-left')
          ? '${id.substring(0, id.length - 5)}-right'
          : id.endsWith('-right')
          ? '${id.substring(0, id.length - 6)}-left'
          : null;
      var peer = pairedId == null
          ? -1
          : entries.indexWhere((e) => e is Map && e['id'] == pairedId);
      if (peer < 0) {
        peer = entries.indexWhere(
          (e) =>
              e is Map &&
              e != selected &&
              e['mount'] is List &&
              (e['mount'] as List)[2] == mount[2] &&
              (e['mount'] as List)[0] == -(mount[0] as num),
        );
      }
      if (peer < 0) return;
      entries.removeAt(index > peer ? index : peer);
      entries.removeAt(index < peer ? index : peer);
    } else {
      entries.removeAt(index);
    }
    onChanged(entries);
  }

  List<Widget> _fields(List<dynamic> rows, int index, bool list) => [
    for (final entry in (rows[index] as Map).entries)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: GameComponentField(
                key: ValueKey(
                  '$label/$index/${entry.key}/${jsonEncode(entry.value)}',
                ),
                descriptor: GameFieldDescriptor(
                  entry.key.toString(),
                  entry.key.toString(),
                  entry.value is bool
                      ? GameFieldKind.boolean
                      : entry.value is int
                      ? GameFieldKind.integer
                      : entry.value is num
                      ? GameFieldKind.number
                      : entry.value is List &&
                            (entry.value as List).length == 3 &&
                            (entry.value as List).every((v) => v is num)
                      ? GameFieldKind.vector
                      : entry.value is Map || entry.value is List
                      ? GameFieldKind.json
                      : GameFieldKind.text,
                ),
                value: entry.value,
                origin: origin,
                entities: const [],
                enabled: enabled,
                onChanged: (next) {
                  final row = Map<String, Object?>.from(rows[index] as Map)
                    ..[entry.key as String] = next;
                  if (list) {
                    final updated = [...rows];
                    updated[index] = row;
                    onChanged(updated);
                  } else {
                    onChanged(row);
                  }
                },
              ),
            ),
            if (!list)
              IconButton(
                tooltip: 'Remove ${entry.key}',
                icon: const Icon(Icons.remove_circle_outline, size: 18),
                onPressed: enabled
                    ? () => onChanged(
                        Map<String, Object?>.from(value as Map)
                          ..remove(entry.key),
                      )
                    : null,
              ),
          ],
        ),
      ),
  ];
  @override
  Widget build(BuildContext context) {
    final list = value is List;
    final rows = list ? value as List : [value];
    final canAdd = enabled && (value is Map || entryTemplate != null);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      subtitle: origin == GameFieldOrigin.authored ? null : Text(origin.name),
      children: [
        for (var index = 0; index < rows.length; index++)
          if (rows[index] is Map)
            if (list)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text('${(rows[index] as Map)['id'] ?? index + 1}'),
                trailing: IconButton(
                  tooltip: entryBatchSize == 2
                      ? 'Remove wheel pair'
                      : 'Remove entry',
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  onPressed: enabled ? () => _remove(index) : null,
                ),
                children: _fields(rows, index, true),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: _fields(rows, index, false),
              ),
        if (rows.isEmpty || value is Map && (value as Map).isEmpty)
          ZeroState(
            title: 'No entries',
            message: 'Add an entry to configure $label.',
            actionLabel: canAdd ? 'Add entry' : null,
            onAction: canAdd ? () => _add(context) : null,
          )
        else if (canAdd)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.add, size: 16),
              label: Text(entryBatchSize == 2 ? 'Add wheel pair' : 'Add entry'),
            ),
          ),
      ],
    );
  }
}
