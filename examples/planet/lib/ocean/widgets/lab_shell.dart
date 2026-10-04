import 'package:flutter/material.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../scenes/definition.dart';

/// The lab owns controls. The geospatial layer API stays headless.
class OceanLabShell extends StatelessWidget {
  final List<OceanLabSceneDefinition> scenes;
  final String sceneId, status, evidence;
  final OceanLabDetail detail;
  final OceanWaterDebug debug;
  final bool paused, route, busy;
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            flex: 0,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .42,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'Ocean lab',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          _select<String>(
                            label: 'Scene',
                            value: sceneId,
                            items: {
                              for (final scene in scenes) scene.id: scene.name,
                            },
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
                            tooltip: paused
                                ? 'Resume simulation'
                                : 'Pause simulation',
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
                ),
              ),
            ),
          ),
          Expanded(
            child: ClipRect(key: const Key('lab-canvas'), child: canvas),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status,
                    key: const Key('lab-status'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    evidence,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
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
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: const TextStyle(fontSize: 12)),
        Flexible(
          child: DropdownButton<T>(
            key: ValueKey('lab-select-$label'),
            value: value,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final entry in items.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text(
                    entry.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: onChanged == null
                ? null
                : (next) {
                    if (next != null) onChanged(next);
                  },
          ),
        ),
      ],
    ),
  );
}
