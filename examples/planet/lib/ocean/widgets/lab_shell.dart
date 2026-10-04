import 'package:flutter/material.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../scenes/definition.dart';
import '../../photorealistic_layout.dart';

/// The lab owns controls. The geospatial layer API stays headless.
class OceanLabShell extends StatelessWidget {
  final List<OceanLabSceneDefinition> scenes;
  final String sceneId, status, evidence;
  final OceanLabDetail detail;
  final OceanWaterDebug debug;
  final bool paused, route, busy, hasFailure;
  final Map<String, bool> layers;
  final ValueChanged<String> onScene;
  final ValueChanged<OceanLabDetail> onDetail;
  final ValueChanged<OceanWaterDebug> onDebug;
  final void Function(String, bool) onLayer;
  final VoidCallback onPause, onReset, onRoute;
  final Widget canvas;
  const OceanLabShell({
    super.key,
    required this.scenes,
    required this.sceneId,
    required this.detail,
    required this.debug,
    required this.paused,
    required this.route,
    required this.busy,
    this.hasFailure = false,
    required this.layers,
    required this.status,
    required this.evidence,
    required this.onScene,
    required this.onDetail,
    required this.onDebug,
    required this.onLayer,
    required this.onPause,
    required this.onReset,
    required this.onRoute,
    required this.canvas,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PhotorealisticLayout(
        title: 'Ocean',
        infoNeedsAttention: hasFailure,
        scene: ClipRect(key: const Key('lab-canvas'), child: canvas),
        controls: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _select<String>(
                  label: 'Scene',
                  value: sceneId,
                  items: {for (final scene in scenes) scene.id: scene.name},
                  onChanged: busy ? null : onScene,
                ),
                _select<OceanLabDetail>(
                  label: 'Detail',
                  value: detail,
                  items: {
                    for (final value in OceanLabDetail.values)
                      value: value.name,
                  },
                  onChanged: busy ? null : onDetail,
                ),
                _select<OceanWaterDebug>(
                  label: 'View',
                  value: debug,
                  items: {
                    for (final value in OceanWaterDebug.values)
                      value: switch (value) {
                        OceanWaterDebug.color => 'Color',
                        OceanWaterDebug.normal => 'Normals',
                        OceanWaterDebug.waterPath => 'Water depth',
                        OceanWaterDebug.reflectionConfidence =>
                          'Reflection confidence',
                        OceanWaterDebug.foam => 'Foam',
                      },
                  },
                  onChanged: busy ? null : onDebug,
                ),
                IconButton(
                  tooltip: paused ? 'Resume simulation' : 'Pause simulation',
                  onPressed: busy ? null : onPause,
                  icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                ),
                TextButton(
                  onPressed: busy ? null : onReset,
                  child: const Text('Reset camera'),
                ),
                if (sceneId == 'orbit')
                  FilterChip(
                    label: const Text('Fly to ocean'),
                    selected: route,
                    onSelected: busy ? null : (_) => onRoute(),
                  ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final entry in layers.entries)
                  FilterChip(
                    label: Text(entry.key.split('.').last),
                    selected: entry.value,
                    onSelected: busy
                        ? null
                        : (value) => onLayer(entry.key, value),
                  ),
                const Text(
                  'Drag to navigate · Scroll to zoom',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ],
        ),
        info: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              status,
              key: const Key('lab-status'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(evidence, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );

  Widget _select<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T>? onChanged,
  }) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: label == 'Detail' ? 180 : 300),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: const TextStyle(fontSize: 12)),
        DropdownButton<T>(
          key: ValueKey('lab-select-$label'),
          value: value,
          isExpanded: true,
          itemHeight: null,
          underline: const SizedBox.shrink(),
          items: [
            for (final entry in items.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: onChanged == null
              ? null
              : (next) {
                  if (next != null) onChanged(next);
                },
        ),
      ],
    ),
  );
}
