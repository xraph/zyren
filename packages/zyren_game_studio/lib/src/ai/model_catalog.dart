part of '../../ai.dart';

class GameModelCatalog extends StatefulWidget {
  final GameAiWorkspace workspace;
  const GameModelCatalog({super.key, required this.workspace});
  @override
  State<GameModelCatalog> createState() => _GameModelCatalogState();
}

class _GameModelCatalogState extends State<GameModelCatalog> {
  String filter = '';
  @override
  Widget build(BuildContext context) {
    final models = widget.workspace.models.values
        .where(
          (m) =>
              m.contract.model.id.toLowerCase().contains(filter.toLowerCase()),
        )
        .take(64)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            labelText: 'Filter imported models',
            isDense: true,
          ),
          onChanged: (text) => setState(() => filter = text),
        ),
        if (models.isEmpty && widget.workspace.models.isNotEmpty)
          const ZeroState(
            title: 'No matching models',
            message: 'Clear the filter to see your imported model candidates.',
          ),
        for (final model in models)
          ListTile(
            dense: true,
            title: Text(model.contract.model.id),
            subtitle: Text(
              '${model.compatible ? 'compatible' : 'incompatible'} · ${model.accepted ? 'evaluated' : 'evaluation required'}',
            ),
            onTap: () {
              widget.workspace.candidate = model;
              widget.workspace.refresh();
            },
          ),
      ],
    );
  }
}
