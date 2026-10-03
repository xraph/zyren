import 'studio_material_editor.dart';
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
  return showDialog<StudioDocument>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Material: ${node.label}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: StudioMaterialEditor(
            value: value,
            onApply: (material) {
              Navigator.pop(
                context,
                StudioAuthoring.updateNode(
                  document,
                  id,
                  StudioOverride(material: material),
                ),
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
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
                        icon: const Icon(
                          Icons.delete_outline,
                          semanticLabel: 'Remove note',
                        ),
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

Future<StudioDocument?> studioClipsDialog(
  BuildContext context,
  StudioDocument document,
) async {
  var draft = document;
  var clipId = draft.clips.first.id;
  String? error;
  return showDialog<StudioDocument>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        final clip = draft.clips.where((c) => c.id == clipId).firstOrNull;
        void edit(StudioDocument Function() change) {
          try {
            final next = change();
            update(() {
              draft = next;
              error = null;
            });
          } catch (failure) {
            update(() => error = '$failure');
          }
        }

        Future<int?> time(String title, int initial) async {
          final text = TextEditingController(text: '${initial / 1000000}');
          try {
            return await showDialog<int>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(title),
                content: TextField(
                  controller: text,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Seconds'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      final value = double.tryParse(text.text);
                      if (value != null && value.isFinite) {
                        Navigator.pop(context, (value * 1000000).round());
                      }
                    },
                    child: const Text('Apply'),
                  ),
                ],
              ),
            );
          } finally {
            text.dispose();
          }
        }

        return AlertDialog(
          title: const Text('Animation clips'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (draft.clips.isEmpty)
                    const ZeroState(
                      title: 'No clips',
                      message:
                          'Apply to remove the last clip, or cancel to keep it.',
                    ),
                  if (draft.clips.isNotEmpty)
                    DropdownButton<String>(
                      isExpanded: true,
                      value: clip?.id,
                      hint: const Text('Choose clip'),
                      items: [
                        for (final c in draft.clips)
                          DropdownMenuItem(value: c.id, child: Text(c.label)),
                      ],
                      onChanged: (value) => update(() => clipId = value!),
                    ),
                  if (clip != null) ...[
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton(
                          onPressed: () async {
                            final value = await time(
                              'Clip duration',
                              clip.durationMicroseconds,
                            );
                            if (value != null) {
                              edit(
                                () => StudioAuthoring.resizeClip(
                                  draft,
                                  clip.id,
                                  value,
                                ),
                              );
                            }
                          },
                          child: Text(
                            'Duration ${clip.durationMicroseconds / 1000000}s',
                          ),
                        ),
                        TextButton(
                          onPressed: () => edit(
                            () => draft.copyWith(
                              clips: draft.clips.where((c) => c.id != clip.id),
                            ),
                          ),
                          child: const Text('Remove clip'),
                        ),
                      ],
                    ),
                    for (final track in clip.tracks.entries) ...[
                      Text(draft.expandedNodes[track.key]?.label ?? track.key),
                      for (final frame in track.value)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${frame.microseconds / 1000000}s  (${frame.position.x}, ${frame.position.y}, ${frame.position.z})',
                                maxLines: 2,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Retime key',
                              icon: const Icon(
                                Icons.schedule,
                                semanticLabel: 'Retime key',
                              ),
                              onPressed: () async {
                                final value = await time(
                                  'Move key',
                                  frame.microseconds,
                                );
                                if (value != null) {
                                  edit(
                                    () => StudioAuthoring.editKeyframe(
                                      draft,
                                      clipId: clip.id,
                                      nodeId: track.key,
                                      microseconds: frame.microseconds,
                                      moveToMicroseconds: value,
                                    ),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              tooltip: 'Remove key',
                              icon: const Icon(
                                Icons.delete_outline,
                                semanticLabel: 'Remove key',
                              ),
                              onPressed: () => edit(
                                () => StudioAuthoring.editKeyframe(
                                  draft,
                                  clipId: clip.id,
                                  nodeId: track.key,
                                  microseconds: frame.microseconds,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ],
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
              onPressed: () => Navigator.pop(context, draft),
              child: const Text('Apply clips'),
            ),
          ],
        );
      },
    ),
  );
}
