import 'dart:math' as math;
import 'package:zyren_studio/zyren_studio.dart';
import 'studio_material_editor.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

class StudioProperties extends StatelessWidget {
  final Object3D? object;
  final List<Widget> sections;
  final StudioEditorPlacementBinding? placement;
  final ValueChanged<Vec3>? onPosition, onScale;
  final ValueChanged<Quat>? onRotation;
  final ValueChanged<bool>? onVisible;
  final StudioMaterial? material;
  final ValueChanged<StudioMaterial>? onMaterialChanged;
  final VoidCallback? onMaterial, onPose, onNudge;
  const StudioProperties({
    super.key,
    required this.object,
    this.sections = const [],
    this.placement,
    this.onPosition,
    this.onRotation,
    this.onVisible,
    this.material,
    this.onMaterialChanged,
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
        SwitchListTile.adaptive(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Visible'),
          value: selected.visible,
          onChanged: onVisible,
        ),
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
          validate: (v) => v.x == 0 || v.y == 0 || v.z == 0 ? 'Nonzero' : null,
        ),
        const SizedBox(height: 10),
        _VectorFields(
          label: 'Rotation (degrees)',
          value: rotationDegrees(q),
          onChanged: onRotation == null
              ? null
              : (value) => onRotation!(rotationFromDegrees(value)),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: onRotation == null
                  ? null
                  : () => onRotation!(Quat.identity),
              child: const Text('Reset rotation'),
            ),
            TextButton(
              onPressed: onScale == null ? null : () => onScale!(Vec3.one),
              child: const Text('Reset scale'),
            ),
          ],
        ),
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
        if (material != null && onMaterialChanged != null)
          StudioMaterialEditor(
            key: ValueKey(material!.toJson().toString()),
            value: material!,
            onApply: onMaterialChanged!,
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

/// Intrinsic XYZ Euler controls in degrees; quaternions remain the saved value.
Vec3 rotationDegrees(Quat rotation) {
  final q = rotation.normalized();
  final m02 = 2 * (q.x * q.z + q.y * q.w);
  final y = math.asin(m02.clamp(-1.0, 1.0));
  final x = m02.abs() < .9999999
      ? math.atan2(2 * (q.x * q.w - q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
      : math.atan2(
          2 * (q.y * q.z + q.x * q.w),
          1 - 2 * (q.x * q.x + q.z * q.z),
        );
  final z = m02.abs() < .9999999
      ? math.atan2(2 * (q.z * q.w - q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
      : 0.0;
  return Vec3(x, y, z) * (180 / math.pi);
}

Quat rotationFromDegrees(Vec3 value) =>
    Quat.axisAngle(const Vec3(1, 0, 0), value.x * math.pi / 180) *
    Quat.axisAngle(const Vec3(0, 1, 0), value.y * math.pi / 180) *
    Quat.axisAngle(const Vec3(0, 0, 1), value.z * math.pi / 180);
