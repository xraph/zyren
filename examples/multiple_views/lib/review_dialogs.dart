import 'package:flutter/material.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

class ReviewMetadataDialog extends StatefulWidget {
  final EngineeringObject record;
  const ReviewMetadataDialog({super.key, required this.record});
  @override
  State<ReviewMetadataDialog> createState() => _MetadataState();
}

class _MetadataState extends State<ReviewMetadataDialog> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.record.label);
  late final _tag = TextEditingController(
    text: '${widget.record.properties['tag'] ?? ''}',
  );
  late final _material = TextEditingController(
    text: '${widget.record.properties['material'] ?? ''}',
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Part metadata'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'ID: ${widget.record.id}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextFormField(
                key: const ValueKey('metadata-label'),
                controller: _label,
                maxLength: 240,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (value) =>
                    value!.trim().isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                key: const ValueKey('metadata-tag'),
                controller: _tag,
                maxLength: 128,
                decoration: const InputDecoration(labelText: 'Tag'),
              ),
              TextFormField(
                key: const ValueKey('metadata-material'),
                controller: _material,
                maxLength: 128,
                decoration: const InputDecoration(labelText: 'Material'),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final properties = {...widget.record.properties};
          for (final entry in {
            'tag': _tag.text.trim(),
            'material': _material.text.trim(),
          }.entries) {
            if (entry.value.isEmpty) {
              properties.remove(entry.key);
            } else {
              properties[entry.key] = entry.value;
            }
          }
          Navigator.pop(
            context,
            EngineeringObject(
              id: widget.record.id,
              label: _label.text.trim(),
              properties: properties,
            ),
          );
        },
        child: const Text('Apply'),
      ),
    ],
  );
  @override
  void dispose() {
    _label.dispose();
    _tag.dispose();
    _material.dispose();
    super.dispose();
  }
}

class ReviewNoteDialog extends StatefulWidget {
  final String text;
  const ReviewNoteDialog({super.key, this.text = ''});
  @override
  State<ReviewNoteDialog> createState() => _NoteState();
}

class _NoteState extends State<ReviewNoteDialog> {
  final _form = GlobalKey<FormState>();
  late final _text = TextEditingController(text: widget.text);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Review note'),
    content: SizedBox(
      width: 360,
      child: Form(
        key: _form,
        child: TextFormField(
          key: const ValueKey('annotation-text'),
          controller: _text,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          maxLength: 4096,
          decoration: const InputDecoration(labelText: 'Note'),
          validator: (value) => value!.trim().isEmpty ? 'Enter a note' : null,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _text.text.trim());
          }
        },
        child: const Text('Apply'),
      ),
    ],
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
