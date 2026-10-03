import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

Future<StudioDocument?> studioMaterialDialog(
  BuildContext context,
  StudioDocument document,
  String id,
) async {
  final node = document.expandedNodes[id]!;
  final value = node.material ?? StudioMaterial(color: node.color);
  var kind = value.kind;
  var doubleSided = value.doubleSided;
  final fields = <String, TextEditingController>{
    'Color (hex)': TextEditingController(
      text: value.color.toRadixString(16).padLeft(6, '0'),
    ),
    'Opacity': TextEditingController(text: '${value.opacity}'),
    'Metallic': TextEditingController(text: '${value.metallic}'),
    'Roughness': TextEditingController(text: '${value.roughness}'),
    'Emissive (hex)': TextEditingController(
      text: value.emissive.toRadixString(16).padLeft(6, '0'),
    ),
    'Emissive intensity': TextEditingController(
      text: '${value.emissiveIntensity}',
    ),
  };
  String? error;
  try {
    return await showDialog<StudioDocument>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Material: ${node.label}'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<StudioMaterialKind>(
                    initialValue: kind,
                    decoration: const InputDecoration(labelText: 'Shading'),
                    items: [
                      for (final value in StudioMaterialKind.values)
                        DropdownMenuItem(value: value, child: Text(value.name)),
                    ],
                    onChanged: (value) => update(() => kind = value!),
                  ),
                  for (final entry in fields.entries)
                    TextField(
                      controller: entry.value,
                      decoration: InputDecoration(labelText: entry.key),
                      keyboardType: TextInputType.text,
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Double sided'),
                    value: doubleSided,
                    onChanged: (value) => update(() => doubleSided = value!),
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
                  final material = StudioMaterial(
                    kind: kind,
                    doubleSided: doubleSided,
                    color: int.parse(
                      fields['Color (hex)']!.text.replaceFirst('#', ''),
                      radix: 16,
                    ),
                    emissive: int.parse(
                      fields['Emissive (hex)']!.text.replaceFirst('#', ''),
                      radix: 16,
                    ),
                    opacity: double.parse(fields['Opacity']!.text),
                    metallic: double.parse(fields['Metallic']!.text),
                    roughness: double.parse(fields['Roughness']!.text),
                    emissiveIntensity: double.parse(
                      fields['Emissive intensity']!.text,
                    ),
                  );
                  Navigator.pop(
                    context,
                    StudioAuthoring.updateNode(
                      document,
                      id,
                      StudioOverride(material: material),
                    ),
                  );
                } catch (_) {
                  update(
                    () => error =
                        'Use six-digit colors, values from 0 to 1, and emissive intensity from 0 to 1000.',
                  );
                }
              },
              child: const Text('Apply material'),
            ),
          ],
        ),
      ),
    );
  } finally {
    for (final field in fields.values) {
      field.dispose();
    }
  }
}

Future<StudioDocument?> studioKeyframeDialog(
  BuildContext context,
  StudioDocument document,
  String id,
) async {
  final node = document.expandedNodes[id]!;
  final clip = document.clips.firstOrNull;
  final name = TextEditingController(text: clip?.id ?? 'animation');
  final time = TextEditingController(text: '0');
  final duration = TextEditingController(
    text: '${(clip?.durationMicroseconds ?? 3000000) / 1000000}',
  );
  String? error;
  try {
    return await showDialog<StudioDocument>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Keyframe: ${node.label}'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Move the object in the editor, then save its pose at a time. Recording at an existing time replaces that keyframe.',
                  ),
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Clip ID'),
                  ),
                  TextField(
                    controller: time,
                    decoration: const InputDecoration(
                      labelText: 'Time (seconds)',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: duration,
                    decoration: const InputDecoration(
                      labelText: 'Duration (seconds)',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  if (clip != null)
                    Text(
                      '${clip.tracks.values.fold(0, (int n, frames) => n + frames.length)} saved keyframes',
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
                  final next = StudioAuthoring.putKeyframe(
                    document,
                    clipId: name.text,
                    nodeId: id,
                    frame: StudioKeyframe(
                      microseconds: (double.parse(time.text) * 1000000).round(),
                      position: node.position,
                      rotation: node.rotation,
                      scale: node.scale,
                      visible: node.visible,
                    ),
                    durationMicroseconds:
                        (double.parse(duration.text) * 1000000).round(),
                  );
                  Navigator.pop(context, next);
                } catch (_) {
                  update(
                    () => error =
                        'Enter a clip ID, a positive duration up to 24 hours, and a time within that duration.',
                  );
                }
              },
              child: const Text('Record pose'),
            ),
          ],
        ),
      ),
    );
  } finally {
    name.dispose();
    time.dispose();
    duration.dispose();
  }
}

Future<StudioDocument?> studioReviewDialog(
  BuildContext context,
  StudioDocument document,
  String sourceId,
) async {
  final notes = document.review.annotations.values
      .where((n) => n.objectId == sourceId)
      .toList();
  final text = TextEditingController();
  String? error;
  try {
    return await showDialog<StudioDocument>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Engineering notes'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (notes.isEmpty)
                    const ZeroState(
                      title: 'No notes yet',
                      message: 'Add a note for this source object.',
                    ),
                  for (final note in notes)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(note.text),
                      trailing: IconButton(
                        tooltip: 'Remove note',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => update(() => notes.remove(note)),
                      ),
                    ),
                  TextField(
                    controller: text,
                    maxLines: 3,
                    maxLength: 4096,
                    decoration: const InputDecoration(labelText: 'New note'),
                  ),
                  if (error != null) Text(error!),
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
                  final annotations = [
                    for (final note in document.review.annotations.values)
                      if (note.objectId != sourceId) note,
                    ...notes,
                    if (text.text.trim().isNotEmpty)
                      EngineeringAnnotation(
                        id: 'note-${DateTime.now().microsecondsSinceEpoch}',
                        objectId: sourceId,
                        text: text.text.trim(),
                        anchor: Vec3.zero,
                      ),
                  ];
                  Navigator.pop(
                    context,
                    document.copyWith(
                      review: EngineeringDocument(
                        id: document.id,
                        objects: document.review.objects.values,
                        annotations: annotations,
                      ),
                    ),
                  );
                } catch (failure) {
                  update(() => error = '$failure');
                }
              },
              child: const Text('Save notes'),
            ),
          ],
        ),
      ),
    );
  } finally {
    text.dispose();
  }
}
