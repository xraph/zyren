import 'dart:math' as math;
import 'package:flutter/material.dart';

const scientificModes = [
  'Slice',
  'Isosurface',
  'Vectors',
  'Streamline',
  'Temporal',
  'Volume',
];

ThemeData scientificTheme() => ThemeData.dark(useMaterial3: true).copyWith(
  visualDensity: VisualDensity.standard,
  materialTapTargetSize: MaterialTapTargetSize.padded,
);

class ScientificControls extends StatefulWidget {
  final String selected, unit, presentation, undoLabel, redoLabel;
  final bool busy, ready, canUndo, canRedo;
  final double time, threshold;
  final ValueChanged<String> onMode, onCamera;
  final ValueChanged<double> onPreview, onCommit;
  final VoidCallback onUndo, onRedo, onSample;
  const ScientificControls({
    super.key,
    required this.selected,
    required this.unit,
    required this.presentation,
    required this.busy,
    required this.ready,
    required this.canUndo,
    required this.canRedo,
    required this.undoLabel,
    required this.redoLabel,
    required this.time,
    required this.threshold,
    required this.onMode,
    required this.onCamera,
    required this.onPreview,
    required this.onCommit,
    required this.onUndo,
    required this.onRedo,
    required this.onSample,
  });

  @override
  State<ScientificControls> createState() => _ScientificControlsState();
}

class _ScientificControlsState extends State<ScientificControls> {
  bool showCamera = false;
  @override
  Widget build(BuildContext context) {
    final ScientificControls(
      :selected,
      :unit,
      :presentation,
      :undoLabel,
      :redoLabel,
      :busy,
      :ready,
      :canUndo,
      :canRedo,
      :time,
      :threshold,
      :onMode,
      :onCamera,
      :onPreview,
      :onCommit,
      :onUndo,
      :onRedo,
      :onSample,
    ) = widget;

    final enabled = ready && !busy, temporal = selected == 'Temporal';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Scientific lab',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text('SYNTHETIC · $unit · m'),
              Text(presentation, key: const ValueKey('presentation-status')),
            ],
          ),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: [
              for (final mode in scientificModes)
                ChoiceChip(
                  key: ValueKey('mode-$mode'),
                  label: Text(mode),
                  selected: selected == mode,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: enabled ? (_) => onMode(mode) : null,
                ),
            ],
          ),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                key: const ValueKey('undo'),
                tooltip: 'Undo${canUndo ? ': $undoLabel' : ''}',
                onPressed: enabled && canUndo ? onUndo : null,
                icon: Icon(
                  Icons.undo,
                  semanticLabel: 'Undo${canUndo ? ': $undoLabel' : ''}',
                ),
              ),
              IconButton(
                key: const ValueKey('redo'),
                tooltip: 'Redo${canRedo ? ': $redoLabel' : ''}',
                onPressed: enabled && canRedo ? onRedo : null,
                icon: Icon(
                  Icons.redo,
                  semanticLabel: 'Redo${canRedo ? ': $redoLabel' : ''}',
                ),
              ),
              TextButton.icon(
                key: const ValueKey('sample-source'),
                onPressed: enabled ? onSample : null,
                icon: const Icon(Icons.my_location),
                label: const Text('Sample source'),
              ),
              IconButton(
                tooltip: 'Camera controls',
                icon: const Icon(
                  Icons.threed_rotation,
                  semanticLabel: 'Camera controls',
                ),
                isSelected: showCamera,
                onPressed: enabled
                    ? () => setState(() => showCamera = !showCamera)
                    : null,
              ),
            ],
          ),
          if (showCamera)
            Wrap(
              spacing: 4,
              children: [
                for (final action in [
                  'Rotate left',
                  'Rotate right',
                  'Rotate up',
                  'Rotate down',
                  'Zoom in',
                  'Zoom out',
                  'Reset camera',
                ])
                  TextButton(
                    onPressed: enabled ? () => onCamera(action) : null,
                    child: Text(action),
                  ),
              ],
            ),
          if (selected == 'Isosurface' || temporal)
            Row(
              children: [
                Flexible(
                  child: Text(
                    temporal
                        ? 'Time ${time.toStringAsFixed(2)} s'
                        : '${threshold.toStringAsFixed(1)} K',
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: MergeSemantics(
                    key: const ValueKey('field-slider'),
                    child: Semantics(
                      label: temporal
                          ? 'Simulation time'
                          : 'Isosurface threshold',
                      child: Slider(
                        value: temporal ? time : threshold,
                        min: temporal ? 0 : math.min(274, threshold),
                        max: temporal ? 2 : math.max(312, threshold),
                        divisions: temporal ? 20 : 76,
                        semanticFormatterCallback: (value) => temporal
                            ? '${value.toStringAsFixed(2)} seconds'
                            : '${value.toStringAsFixed(1)} kelvin',
                        onChanged: enabled ? onPreview : null,
                        onChangeEnd: enabled ? onCommit : null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          if (busy)
            const LinearProgressIndicator(
              minHeight: 2,
              semanticsLabel: 'Updating scientific view',
            ),
        ],
      ),
    );
  }
}

class ScientificProbe extends StatefulWidget {
  final List<double> maximum;
  final String unit;
  final String Function(List<double>) sample;
  final bool enabled;
  final VoidCallback onClose;
  const ScientificProbe({
    super.key,
    required this.maximum,
    required this.unit,
    required this.sample,
    required this.enabled,
    required this.onClose,
  });
  @override
  State<ScientificProbe> createState() => _ScientificProbeState();
}

class _ScientificProbeState extends State<ScientificProbe> {
  late final List<double> position = widget.maximum.map((v) => v / 2).toList();
  @override
  void didUpdateWidget(ScientificProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (var axis = 0; axis < 3; axis++) {
      position[axis] = position[axis].clamp(0, widget.maximum[axis]);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(header: true, child: const Text('Sample source')),
            TextButton(onPressed: widget.onClose, child: const Text('Close')),
          ],
        ),
        for (var axis = 0; axis < 3; axis++)
          Row(
            children: [
              Text(['X', 'Y', 'Z'][axis]),
              Expanded(
                child: MergeSemantics(
                  key: ValueKey('probe-$axis'),
                  child: Semantics(
                    label: '${['X', 'Y', 'Z'][axis]} source coordinate',
                    child: Slider(
                      value: position[axis],
                      min: 0,
                      max: widget.maximum[axis],
                      divisions: 40,
                      semanticFormatterCallback: (v) =>
                          '${v.toStringAsFixed(3)} ${widget.unit}',
                      onChanged: widget.enabled
                          ? (v) => setState(() => position[axis] = v)
                          : null,
                    ),
                  ),
                ),
              ),
            ],
          ),
        Semantics(
          liveRegion: true,
          child: Text(
            widget.sample(position),
            key: const ValueKey('probe-value'),
          ),
        ),
      ],
    ),
  );
}
