part of '../../play.dart';

class GameRuntimeInspector extends StatelessWidget {
  final GamePlaySession session;
  const GameRuntimeInspector({super.key, required this.session});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (_, _) {
      final entities =
          session.simulation?.session.entities.entities ??
          <GameRuntimeEntity>[];
      final selected = session.runtimeSelection;
      Map<String, Object?>? values;
      try {
        if (selected != null) values = session.inspectEntity(selected);
      } catch (_) {}
      return ListView(
        shrinkWrap: true,
        children: [
          DropdownButtonFormField<GameEntityHandle>(
            initialValue: values == null ? null : selected,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Runtime entity',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final entity in entities)
                DropdownMenuItem(
                  value: entity.handle,
                  child: Text(
                    entity.handle.id,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => session.runtimeSelection = value,
          ),
          if (values == null)
            const ZeroState(
              title: 'Select a runtime entity',
              message:
                  'Inspect controller and physics values without changing authored data.',
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '${values['actor']} · ${values['controller']} · tick ${values['tick']}',
              ),
            ),
            if (values.containsKey('position'))
              Text('Position: ${values['position']}'),
            if (values.containsKey('velocity'))
              Text('Velocity: ${values['velocity']}'),
            if (values.containsKey('wheels'))
              Text(
                'Wheel contacts: ${(values['wheels'] as List).where((w) => (w as Map)['contact'] != null).length}',
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Component definitions'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(values['components']),
                ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
