import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

class StudioProperties extends StatelessWidget {
  final Object3D? object;
  final List<Widget> sections;
  final StudioEditorPlacementBinding? placement;
  final ValueChanged<Vec3>? onPosition, onScale;
  final VoidCallback? onMaterial, onPose, onNudge;
  const StudioProperties({
    super.key,
    required this.object,
    this.sections = const [],
    this.placement,
    this.onPosition,
    this.onScale,
    this.onMaterial,
    this.onPose,
    this.onNudge,
  });

  @override
  Widget build(BuildContext context) {
    final selected = object;
    if (selected == null) {
      return const ZeroState(
        title: 'No selection',
        message:
            'Select an object in the scene or viewport to inspect its properties.',
      );
    }
    Vec3 displayedPosition;
    try {
      displayedPosition =
          placement?.toDisplay(selected.position) ?? selected.position;
    } catch (error) {
      return ZeroState(title: 'Placement unavailable', message: '$error');
    }
    final q = selected.quaternion;
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        Row(
          children: [
            const Icon(Icons.view_in_ar_outlined, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                selected.name ?? 'Object',
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Transform', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _VectorFields(
          label: placement?.definition.title ?? 'Position',
          axes: placement?.definition.labels ?? const ['X', 'Y', 'Z'],
          units: placement?.definition.units ?? const ['', '', ''],
          precision: placement?.definition.precision ?? 3,
          value: displayedPosition,
          validate: placement == null
              ? null
              : (value) {
                  try {
                    placement!.toLocal(value);
                    return null;
                  } catch (_) {
                    return 'Out of range';
                  }
                },
          onChanged: onPosition == null
              ? null
              : (value) => onPosition!(placement?.toLocal(value) ?? value),
        ),
        const SizedBox(height: 10),
        _VectorFields(
          label: 'Scale',
          value: selected.scale,
          onChanged: onScale,
        ),
        const SizedBox(height: 10),
        Text(
          'Rotation (quaternion)',
          style: Theme.of(context).textTheme.labelSmall,
        ),
        const SizedBox(height: 4),
        Text(
          [q.x, q.y, q.z, q.w].map((v) => v.toStringAsFixed(3)).join('   '),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        if (placement == null)
          Text(
            'X ${selected.position.x.toStringAsFixed(2)}  Y ${selected.position.y.toStringAsFixed(2)}  Z ${selected.position.z.toStringAsFixed(2)}',
            key: const ValueKey('selection-position'),
            style: Theme.of(context).textTheme.labelSmall,
          ),
        Wrap(
          spacing: 4,
          children: [
            if (placement == null)
              TextButton(onPressed: onNudge, child: const Text('X +0.25')),
            TextButton(onPressed: onPose, child: const Text('Record pose')),
          ],
        ),
        const Divider(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                'Material',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton(
              onPressed: onMaterial,
              child: const Text('Edit material'),
            ),
          ],
        ),
        Text(
          'Changes use the scene’s undo history.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        ...sections,
      ],
    );
  }
}

class _VectorFields extends StatelessWidget {
  final String label;
  final Vec3 value;
  final ValueChanged<Vec3>? onChanged;
  final List<String> axes, units;
  final int precision;
  final String? Function(Vec3)? validate;
  const _VectorFields({
    required this.label,
    required this.value,
    this.onChanged,
    this.axes = const ['X', 'Y', 'Z'],
    this.units = const ['', '', ''],
    this.precision = 3,
    this.validate,
  });
  @override
  Widget build(BuildContext context) {
    final values = [value.x, value.y, value.z];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 4),
        Row(
          children: [
            for (var index = 0; index < 3; index++) ...[
              if (index > 0) const SizedBox(width: 5),
              Expanded(
                child: TextFormField(
                  key: ValueKey('$label-$index-${values[index]}'),
                  initialValue: values[index].toStringAsFixed(precision),
                  enabled: onChanged != null,
                  style: const TextStyle(fontSize: 11),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '$label ${axes[index]}',
                    helperText: units[index].isEmpty ? null : units[index],
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    prefixText:
                        '${axes[index].length > 3 ? axes[index].substring(0, 3) : axes[index]}  ',
                  ),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (input) {
                    final parsed = double.tryParse(input ?? '');
                    if (parsed == null || !parsed.isFinite) return 'Number';
                    final next = List<double>.of(values)..[index] = parsed;
                    return validate?.call(Vec3(next[0], next[1], next[2]));
                  },
                  onFieldSubmitted: (input) {
                    final parsed = double.tryParse(input);
                    if (parsed == null || !parsed.isFinite) return;
                    final next = List<double>.of(values)..[index] = parsed;
                    final value = Vec3(next[0], next[1], next[2]);
                    if (validate?.call(value) == null) onChanged?.call(value);
                  },
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
