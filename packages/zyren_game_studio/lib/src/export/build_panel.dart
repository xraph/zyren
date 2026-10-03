part of '../../export_ui.dart';

class GameBuildPanel extends StatefulWidget {
  final GameBuildCommands commands;
  final GameCollaborationAdapter? collaboration;
  final Future<void> Function()? leaveSession, importAssets;
  const GameBuildPanel({
    super.key,
    required this.commands,
    this.collaboration,
    this.leaveSession,
    this.importAssets,
  });
  @override
  State<GameBuildPanel> createState() => _GameBuildPanelState();
}

class _GameBuildPanelState extends State<GameBuildPanel> {
  String? _error;
  void _start() {
    try {
      final result = widget.commands.startNewBuild(
        expectedRevision: widget.commands.revision(),
      );
      setState(
        () => _error = switch (result) {
          StartedBuildResult() => null,
          DeniedBuildResult() => 'The host has not granted game build access.',
          InvalidBuildResult() => result.diagnostics.join('\n'),
          StaleBuildResult() =>
            'The document changed. Refresh and export again.',
          UnavailableBuildResult() =>
            'A build is active or this build host is unavailable.',
        },
      );
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.commands.changes,
    builder: (context, _) {
      final commands = widget.commands;
      final jobs = commands.jobs;
      final available = !commands.isClosed && commands.isAvailable();
      final allowed = available && commands.allows('game.build');
      final active = commands.activeJobs.isNotEmpty;
      final profile = available ? commands.profile() : null;
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Revision ${commands.revision()}'),
              if (profile != null) Text('${profile.fixedHz} Hz'),
              if (profile != null)
                Text('Requires: ${profile.capabilities.join(", ")}'),
              TextButton.icon(
                onPressed: allowed && !active ? _start : null,
                icon: const Icon(Icons.file_download_outlined, size: 18),
                label: const Text('Export'),
              ),
            ],
          ),
          SelectableText(commands.currentOutputLabel),
          Text(
            'Pinned assets: ${commands.documents().fold<int>(0, (n, d) => n + d.assets.length)} · Models: ${commands.models().length} · Pipeline jobs: ${jobs.length}',
          ),
          if (widget.collaboration?.limitation case final String limitation)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(limitation),
                if (widget.leaveSession != null)
                  TextButton(
                    onPressed: widget.leaveSession,
                    child: const Text('Leave session'),
                  ),
              ],
            ),
          if (available && commands.validationDiagnostics.isNotEmpty)
            ZeroState(
              title: 'Build validation failed',
              message: commands.validationDiagnostics.join('\n'),
            ),
          if (_error != null || !allowed)
            ZeroState(
              title: available
                  ? 'Export access required'
                  : 'Build host unavailable',
              message:
                  _error ??
                  'You need the host game.build grant before creating a build job.',
            ),
          if (jobs.isEmpty && allowed)
            ZeroState(
              title: 'No game exports',
              message:
                  'Export the current saved definitions and pinned assets for offline play.',
              actionLabel: 'Export game',
              onAction: _start,
            ),
          for (final job in jobs.reversed)
            if (job.state == PipelineBuildState.failed)
              ZeroState(
                title: 'Game export failed',
                message: job.errorCode ?? 'Pipeline validation failed.',
                action: Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: allowed && !active ? _start : null,
                      child: const Text('Retry export'),
                    ),
                    if (widget.importAssets != null)
                      TextButton(
                        onPressed: widget.importAssets,
                        child: const Text('Import assets'),
                      ),
                  ],
                ),
              )
            else
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${job.id}: ${job.state.name}'),
                subtitle: job.result == null
                    ? null
                    : SelectableText(job.result!.bundle.version),
                trailing: job.state == PipelineBuildState.running
                    ? TextButton(
                        onPressed: allowed
                            ? () => commands.cancel(job.id)
                            : null,
                        child: const Text('Cancel'),
                      )
                    : null,
              ),
        ],
      );
    },
  );
}
