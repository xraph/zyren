import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

class StudioProperties extends StatelessWidget {
  final Object3D? object;
  final ValueChanged<Vec3>? onPosition, onScale;
  final VoidCallback? onMaterial, onPose, onNudge;
  const StudioProperties({
    super.key,
    required this.object,
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
          label: 'Position',
          value: selected.position,
          onChanged: onPosition,
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
        Text(
          'X ${selected.position.x.toStringAsFixed(2)}  Y ${selected.position.y.toStringAsFixed(2)}  Z ${selected.position.z.toStringAsFixed(2)}',
          key: const ValueKey('selection-position'),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Wrap(
          spacing: 4,
          children: [
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
      ],
    );
  }
}

class _VectorFields extends StatelessWidget {
  final String label;
  final Vec3 value;
  final ValueChanged<Vec3>? onChanged;
  const _VectorFields({
    required this.label,
    required this.value,
    this.onChanged,
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
                  initialValue: values[index].toStringAsFixed(3),
                  enabled: onChanged != null,
                  style: const TextStyle(fontSize: 11),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: '$label ${['X', 'Y', 'Z'][index]}',
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    prefixText: '${['X', 'Y', 'Z'][index]}  ',
                  ),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (input) =>
                      double.tryParse(input ?? '')?.isFinite == true
                      ? null
                      : 'Number',
                  onFieldSubmitted: (input) {
                    final parsed = double.tryParse(input);
                    if (parsed == null || !parsed.isFinite) return;
                    final next = List<double>.of(values)..[index] = parsed;
                    onChanged?.call(Vec3(next[0], next[1], next[2]));
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
