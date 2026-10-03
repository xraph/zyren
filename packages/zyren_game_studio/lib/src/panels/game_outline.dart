part of '../../zyren_game_studio.dart';

class GameOutline extends StatelessWidget {
  final StudioEditorContext context;
  final GameAuthoring authoring;
  const GameOutline({
    super.key,
    required this.context,
    required this.authoring,
  });
  @override
  Widget build(BuildContext buildContext) {
    List<GameEntityRecord> entities;
    try {
      entities = authoring.expanded(context.scene.document).entities;
    } catch (error) {
      return ZeroState(
        title: 'Entities need repair',
        message: error.toString(),
      );
    }
    if (entities.isEmpty) {
      return const ZeroState(
        title: 'No game entities',
        message: 'Select an object and add a game component in its inspector.',
      );
    }
    return ListView.builder(
      itemCount: entities.length,
      itemBuilder: (_, index) {
        final entity = entities[index];
        final node = context.scene.document.expandedNodes[entity.nodeId];
        return ListTile(
          dense: true,
          selected: context.selectedId == entity.nodeId,
          title: Text(
            node?.label ?? entity.id,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            entity.components
                .map((c) => authoring.descriptors[c.type]?.label ?? c.type)
                .join(', '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text('${entity.components.length}'),
          onTap: node == null ? null : () => context.select(node.id),
        );
      },
    );
  }
}
