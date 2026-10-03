part of '../../zyren_game_studio.dart';

class GameProblems extends StatefulWidget {
  final StudioEditorContext context;
  final GameAuthoring authoring;
  const GameProblems({
    super.key,
    required this.context,
    required this.authoring,
  });
  @override
  State<GameProblems> createState() => _GameProblemsState();
}

class _GameProblemsState extends State<GameProblems> {
  String? error;
  bool busy = false;
  Future<void> _repair(GameRepairCommand command) async {
    if (command.kind == GameRepairKind.selectTarget) {
      widget.context.select(command.nodeId);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.context.applyDocument(
        widget.authoring.repair(widget.context.scene.document, command),
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final issues = widget.authoring.validate(widget.context.scene.document);
    if (issues.isEmpty) {
      return const ZeroState(
        title: 'No component problems',
        message:
            'Component data and references passed authoring validation. Runtime checks run when you play.',
      );
    }
    return ListView(
      children: [
        if (error != null)
          ListTile(
            dense: true,
            title: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        for (final issue in issues)
          ListTile(
            dense: true,
            leading: Icon(
              issue.blocksPlay ? Icons.error_outline : Icons.info_outline,
              size: 18,
            ),
            title: Text(issue.message),
            subtitle: Text(
              [
                issue.nodeId,
                issue.component,
                issue.field,
              ].whereType<String>().join(' · '),
            ),
            onTap: issue.nodeId == null
                ? null
                : () => widget.context.select(issue.nodeId),
            trailing: issue.repair == null
                ? null
                : TextButton(
                    onPressed: busy || !widget.context.isAvailable
                        ? null
                        : () => _repair(issue.repair!),
                    child: Text(
                      issue.repair!.kind == GameRepairKind.selectTarget
                          ? 'Select target'
                          : 'Repair',
                    ),
                  ),
          ),
      ],
    );
  }
}
