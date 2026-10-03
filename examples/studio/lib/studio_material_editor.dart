import 'package:flutter/material.dart';
import 'package:zyren_studio/zyren_studio.dart';

class StudioMaterialEditor extends StatefulWidget {
  final StudioMaterial value;
  final ValueChanged<StudioMaterial> onApply;
  const StudioMaterialEditor({
    super.key,
    required this.value,
    required this.onApply,
  });
  @override
  State<StudioMaterialEditor> createState() => _StudioMaterialEditorState();
}

class _StudioMaterialEditorState extends State<StudioMaterialEditor> {
  late StudioMaterialKind kind = widget.value.kind;
  late double opacity = widget.value.opacity,
      metallic = widget.value.metallic,
      roughness = widget.value.roughness;
  late bool doubleSided = widget.value.doubleSided;
  late final color = TextEditingController(
    text: widget.value.color.toRadixString(16).padLeft(6, '0'),
  );
  late final emissive = TextEditingController(
    text: widget.value.emissive.toRadixString(16).padLeft(6, '0'),
  );
  late final intensity = TextEditingController(
    text: '${widget.value.emissiveIntensity}',
  );
  String? error;
  @override
  void dispose() {
    color.dispose();
    emissive.dispose();
    intensity.dispose();
    super.dispose();
  }

  Widget slider(String label, double value, ValueChanged<double> change) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(value.toStringAsFixed(2)),
            ],
          ),
          SizedBox(
            height: 26,
            child: Slider(
              value: value,
              onChanged: (v) => setState(() => change(v)),
              semanticFormatterCallback: (v) =>
                  '$label ${v.toStringAsFixed(2)}',
            ),
          ),
        ],
      );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<StudioMaterialKind>(
        initialValue: kind,
        decoration: const InputDecoration(labelText: 'Shading'),
        items: [
          for (final value in StudioMaterialKind.values)
            DropdownMenuItem(value: value, child: Text(value.name)),
        ],
        onChanged: (v) => setState(() => kind = v!),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: Color(
                0xff000000 |
                    (int.tryParse(
                          color.text.replaceFirst('#', ''),
                          radix: 16,
                        ) ??
                        0),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          Expanded(
            child: TextField(
              controller: color,
              decoration: const InputDecoration(labelText: 'Base color (hex)'),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      slider('Opacity', opacity, (v) => opacity = v),
      if (kind == StudioMaterialKind.standard) ...[
        slider('Metallic', metallic, (v) => metallic = v),
        slider('Roughness', roughness, (v) => roughness = v),
        TextField(
          controller: emissive,
          decoration: const InputDecoration(labelText: 'Emissive color (hex)'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: intensity,
          decoration: const InputDecoration(labelText: 'Emissive intensity'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      ],
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Double sided'),
        value: doubleSided,
        onChanged: (v) => setState(() => doubleSided = v!),
      ),
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () {
            try {
              final next = StudioMaterial(
                kind: kind,
                color: int.parse(color.text.replaceFirst('#', ''), radix: 16),
                opacity: opacity,
                metallic: metallic,
                roughness: roughness,
                emissive: int.parse(
                  emissive.text.replaceFirst('#', ''),
                  radix: 16,
                ),
                emissiveIntensity: double.parse(intensity.text),
                doubleSided: doubleSided,
              );
              widget.onApply(next);
              if (mounted) setState(() => error = null);
            } catch (_) {
              setState(() => error = 'Check color and material values.');
            }
          },
          child: const Text('Apply material'),
        ),
      ),
    ],
  );
}
