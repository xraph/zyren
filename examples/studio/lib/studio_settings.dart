import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:zyren_studio/zyren_studio.dart';

final class StudioViewSettings {
  final StudioEnvironment environment;
  final double fieldOfView, near, far, handleSize;
  final bool grid, fitHandles, snap, worldSpace;
  StudioViewSettings({
    required this.environment,
    required this.fieldOfView,
    required this.near,
    required this.far,
    required this.handleSize,
    required this.grid,
    required this.fitHandles,
    required this.snap,
    required this.worldSpace,
  });
}

Future<StudioViewSettings?> showStudioSettings(
  BuildContext context, {
  required StudioViewSettings current,
  required ThemeMode theme,
  ValueChanged<ThemeMode>? onThemeChanged,
  required VoidCallback onAgentSettings,
}) async {
  final fields = {
    'Background (hex)': TextEditingController(
      text: current.environment.background.toRadixString(16).padLeft(6, '0'),
    ),
    'Ground color (hex)': TextEditingController(
      text: current.environment.groundColor.toRadixString(16).padLeft(6, '0'),
    ),
    'Light pitch (degrees)': TextEditingController(
      text: '${current.environment.keyPitch * 180 / math.pi}',
    ),
    'Light yaw (degrees)': TextEditingController(
      text: '${current.environment.keyYaw * 180 / math.pi}',
    ),
    'Key light': TextEditingController(
      text: '${current.environment.keyIntensity}',
    ),
    'Fill light': TextEditingController(
      text: '${current.environment.fillIntensity}',
    ),
    'Field of view (degrees)': TextEditingController(
      text: '${current.fieldOfView * 180 / math.pi}',
    ),
    'Near clip': TextEditingController(text: '${current.near}'),
    'Far clip': TextEditingController(text: '${current.far}'),
  };
  var grid = current.grid,
      fit = current.fitHandles,
      snap = current.snap,
      world = current.worldSpace;
  var size = current.handleSize, mode = theme;
  var openAgent = false;
  String? error;
  try {
    final route = DialogRoute<StudioViewSettings>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Studio settings'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<ThemeMode>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: 'Appearance'),
                    items: [
                      for (final m in ThemeMode.values)
                        DropdownMenuItem(value: m, child: Text(m.name)),
                    ],
                    onChanged: onThemeChanged == null
                        ? null
                        : (v) {
                            update(() => mode = v!);
                            onThemeChanged(v!);
                          },
                  ),
                  const SizedBox(height: 12),
                  const Text('Scene and camera'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      for (final field in fields.entries)
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width >= 640
                              ? 244
                              : double.infinity,
                          child: TextField(
                            controller: field.value,
                            decoration: InputDecoration(labelText: field.key),
                          ),
                        ),
                    ],
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Editor grid'),
                    value: grid,
                    onChanged: (v) => update(() => grid = v),
                  ),
                  const Divider(),
                  const Text('Transform tools'),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Fit handles to selection'),
                    value: fit,
                    onChanged: (v) => update(() => fit = v),
                  ),
                  Row(
                    children: [
                      const Flexible(child: Text('Maximum handle size')),
                      Expanded(
                        child: Slider(
                          min: 32,
                          max: 160,
                          divisions: 16,
                          value: size,
                          label: '${size.round()} px',
                          onChanged: (v) => update(() => size = v),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('World transform axes'),
                    value: world,
                    onChanged: (v) => update(() => world = v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Snap transforms'),
                    subtitle: const Text('Move 0.25 · rotate 15° · scale 0.1'),
                    value: snap,
                    onChanged: (v) => update(() => snap = v),
                  ),
                  const Divider(),
                  TextButton.icon(
                    onPressed: () {
                      openAgent = true;
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Configure agent model'),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                try {
                  double number(String key) => double.parse(fields[key]!.text);
                  final fov = number('Field of view (degrees)'),
                      near = number('Near clip'),
                      far = number('Far clip');
                  if (!fov.isFinite ||
                      fov < 5 ||
                      fov > 150 ||
                      !near.isFinite ||
                      near <= 0 ||
                      !far.isFinite ||
                      far <= near) {
                    throw ArgumentError();
                  }
                  final environment = StudioEnvironment(
                    background: int.parse(
                      fields['Background (hex)']!.text.replaceFirst('#', ''),
                      radix: 16,
                    ),
                    keyIntensity: number('Key light'),
                    fillIntensity: number('Fill light'),
                    groundColor: int.parse(
                      fields['Ground color (hex)']!.text.replaceFirst('#', ''),
                      radix: 16,
                    ),
                    keyPitch: number('Light pitch (degrees)') * math.pi / 180,
                    keyYaw: number('Light yaw (degrees)') * math.pi / 180,
                  );
                  Navigator.pop(
                    context,
                    StudioViewSettings(
                      environment: environment,
                      fieldOfView: fov * math.pi / 180,
                      near: near,
                      far: far,
                      handleSize: size,
                      grid: grid,
                      fitHandles: fit,
                      snap: snap,
                      worldSpace: world,
                    ),
                  );
                } catch (_) {
                  update(
                    () => error =
                        'Check scene values. FOV must be 5–150°, and 0 < near < far.',
                  );
                }
              },
              child: const Text('Apply settings'),
            ),
          ],
        ),
      ),
    );
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    if (openAgent) onAgentSettings();
    return result;
  } finally {
    for (final field in fields.values) {
      field.dispose();
    }
  }
}
