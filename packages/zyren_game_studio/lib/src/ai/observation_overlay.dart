part of '../../ai.dart';

/// The host provides permitted records or explicitly labeled editor debug data.
class GameObservationOverlay extends StatelessWidget {
  final ObservationFrame frame;
  final bool editorOmniscient;
  const GameObservationOverlay({
    super.key,
    required this.frame,
    this.editorOmniscient = false,
  });
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Align(
      alignment: Alignment.topLeft,
      child: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: .9),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Text(
            '${editorOmniscient ? 'Editor omniscient debug view' : 'NPC permitted observation'} · tick ${frame.tick}\n'
            '${frame.schemaHash}\nVisible records ${frame.entityMask.where((e) => e == 1).length}, unknown slots remain masked',
          ),
        ),
      ),
    ),
  );
}
