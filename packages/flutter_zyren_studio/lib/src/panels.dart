part of '../flutter_zyren_studio.dart';

/// Append these sections to the host's existing selected-object inspector.
class StudioEditorInspectorSections extends StatelessWidget {
  final StudioEditorHostController controller;
  const StudioEditorInspectorSections({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in controller._inspectors.values)
          if (entry.context.isActive && entry.value.applies(entry.context))
            Padding(
              key: ValueKey('studio.inspector.${entry.value.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.value.title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  entry.value.builder(context, entry.context),
                ],
              ),
            ),
      ],
    ),
  );
}

class StudioEditorCreationTools extends StatelessWidget {
  final StudioEditorHostController controller;
  const StudioEditorCreationTools({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final entry in controller._creationTools.values)
          Tooltip(
            message: entry.value.label,
            child: TextButton.icon(
              key: ValueKey('studio.create.${entry.value.id}'),
              onPressed:
                  entry.context.isAvailable &&
                      entry.value.enabled(entry.context)
                  ? () => unawaited(
                      controller
                          .create(entry.value.id)
                          .catchError(_reportEditorError),
                    )
                  : null,
              icon: Icon(entry.value.icon, size: 16),
              label: Text(entry.value.label),
            ),
          ),
      ],
    ),
  );
}

/// The host supplies its file chooser; the registered importer performs the import.
class StudioEditorAssetKinds extends StatelessWidget {
  final StudioEditorHostController controller;
  final Future<Uri?> Function(StudioEditorAssetKind) chooseSource;
  const StudioEditorAssetKinds({
    super.key,
    required this.controller,
    required this.chooseSource,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final entry in controller._assetKinds.values)
          TextButton(
            onPressed: entry.context.isAvailable
                ? () async {
                    try {
                      final source = await chooseSource(entry.value);
                      if (source != null) {
                        await controller.importAsset(entry.value.id, source);
                      }
                    } catch (error, stack) {
                      _reportEditorError(error, stack);
                    }
                  }
                : null,
            child: Text('Import ${entry.value.label}'),
          ),
      ],
    ),
  );
}

class StudioEditorPlayControls extends StatelessWidget {
  final StudioEditorHostController controller;
  const StudioEditorPlayControls({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final active = controller.activePlaySession;
      if (active == null) {
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final entry in controller._playFactories.values)
              TextButton.icon(
                icon: const Icon(Icons.play_arrow, size: 16),
                label: Text(entry.value.label),
                onPressed:
                    entry.context.isAvailable &&
                        entry.value.supports(
                          entry.context,
                          controller.services.scene.document,
                        )
                    ? () => unawaited(
                        controller
                            .startPlay(entry.value.id)
                            .catchError(_reportEditorError),
                      )
                    : null,
              ),
          ],
        );
      }
      return Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          TextButton(
            onPressed: () => unawaited(
              (active.isPaused
                      ? controller.resumePlay()
                      : controller.pausePlay())
                  .catchError(_reportEditorError),
            ),
            child: Text(active.isPaused ? 'Resume' : 'Pause'),
          ),
          TextButton(
            onPressed: active.isPaused
                ? () => unawaited(
                    controller.stepPlay().catchError(_reportEditorError),
                  )
                : null,
            child: const Text('Step'),
          ),
          TextButton(
            onPressed: () =>
                unawaited(controller.stopPlay().catchError(_reportEditorError)),
            child: const Text('Stop'),
          ),
        ],
      );
    },
  );
}

class StudioEditorProblems extends StatefulWidget {
  final StudioEditorHostController controller;
  const StudioEditorProblems({super.key, required this.controller});
  @override
  State<StudioEditorProblems> createState() => _StudioEditorProblemsState();
}

class _StudioEditorProblemsState extends State<StudioEditorProblems> {
  late Future<List<StudioEditorProblem>> _validation = widget.controller
      .validate();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refreshValidation);
  }

  void _refreshValidation() {
    if (mounted) {
      setState(() {
        _validation = widget.controller.validate();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refreshValidation);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StudioEditorProblems oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller.removeListener(_refreshValidation);
      widget.controller.addListener(_refreshValidation);
      _validation = widget.controller.validate();
    }
  }

  void _retry() => setState(() {
    _validation = widget.controller.validate();
  });
  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<StudioEditorProblem>>(
    future: _validation,
    builder: (context, snapshot) {
      if (widget.controller.validatorIds.isEmpty) {
        return const ZeroState(
          title: 'No validators registered',
          message:
              'Attach a contribution that validates this document before reviewing its problems.',
        );
      }
      if (snapshot.hasError) {
        return ZeroState(
          title: 'Validation failed',
          message: '${snapshot.error}',
          actionLabel: 'Retry validation',
          onAction: _retry,
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.data!.isEmpty) {
        return ZeroState(
          title: 'No validation problems',
          message:
              'Registered validators returned no problems for this document.',
          actionLabel: 'Validate again',
          onAction: _retry,
        );
      }
      return ListView(
        children: [
          for (final problem in snapshot.data!)
            ListTile(
              leading: Icon(
                problem.blocking ? Icons.error_outline : Icons.info_outline,
              ),
              title: Text(problem.message),
              subtitle: Text(problem.id),
            ),
        ],
      );
    },
  );
}
