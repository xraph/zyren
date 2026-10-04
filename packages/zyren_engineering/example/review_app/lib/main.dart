import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'review_workspace.dart';

void main() => runApp(const ReviewApp());

class ReviewApp extends StatelessWidget {
  final ReviewWorkspace? workspace;
  const ReviewApp({super.key, this.workspace});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Engineering review',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff216a83),
      brightness: Brightness.dark,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    ),
    home: ReviewPage(workspace: workspace),
  );
}

class ReviewPage extends StatefulWidget {
  final ReviewWorkspace? workspace;
  const ReviewPage({super.key, this.workspace});
  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  late final ReviewWorkspace work;
  bool reviewTab = false;
  final sceneKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    work =
        widget.workspace ??
        ReviewWorkspace(
          runtime: const SceneRuntime.nativeMetal(),
          documentId: const String.fromEnvironment(
            'ZYREN_REVIEW_ID',
            defaultValue: 'review',
          ),
        );
  }

  @override
  void dispose() {
    if (widget.workspace == null) work.dispose();
    super.dispose();
  }

  Future<void> openBundle() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open bundle');
    if (path != null && mounted) await work.open(Directory(path));
  }

  Future<void> saveReview() async {
    final file = await getSaveLocation(suggestedName: 'review-notes.json');
    if (file != null && mounted) await work.save(File(file.path));
  }

  Future<void> loadReview() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Review JSON', extensions: ['json']),
      ],
    );
    if (file == null || !mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Load saved review?'),
        content: const Text(
          'This replaces your local review records. Save current edits first if you need them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Load review'),
          ),
        ],
      ),
    );
    if (proceed == true && mounted) await work.loadNotes(File(file.path));
  }

  Future<void> editNote([EngineeringAnnotation? note]) async {
    final text = TextEditingController(text: note?.text);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(note == null ? 'Add review note' : 'Edit review note'),
        content: SizedBox(
          width: 420,
          child: TextField(
            key: const Key('note-text'),
            controller: text,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 4000,
            decoration: const InputDecoration(labelText: 'Review note'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('save-note'),
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Save note'),
          ),
        ],
      ),
    );
    if (value != null && mounted) work.putNote(value, existing: note);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    text.dispose();
  }

  Future<void> connect() async {
    final url = TextEditingController(
      text: work.endpoint ?? 'https://reviews.example.com/review',
    );
    final token = TextEditingController();
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect shared review'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Document: ${work.review.document.id}. Credentials stay in memory.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('session-url'),
                controller: url,
                decoration: const InputDecoration(
                  labelText: 'HTTPS review endpoint',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('session-token'),
                controller: token,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Access token'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('connect-session'),
            onPressed: () => Navigator.pop(context, (url.text, token.text)),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (result != null && mounted) await work.connect(result.$1, result.$2);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    url.dispose();
    token.dispose();
  }

  Future<void> convert() async {
    final source = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'CAD model',
          extensions: ['ifc', 'step', 'stp', 'iges', 'igs'],
        ),
      ],
    );
    if (source == null || !mounted) return;
    final parent = await getDirectoryPath(
      confirmButtonText: 'Choose output parent',
    );
    if (parent == null || !mounted) return;
    final result = await showDialog<CadOptions>(
      context: context,
      builder: (_) => CadDialog(source: source.name),
    );
    if (result != null && mounted)
      await work.convert(
        python: result.python,
        script: result.script,
        source: source.path,
        destination: '$parent/review-${DateTime.now().microsecondsSinceEpoch}',
        identityMap: result.mapping,
        metersPerUnit: result.scale,
      );
  }

  Widget button(
    String text,
    IconData icon,
    VoidCallback action, {
    bool enabled = true,
    Key? key,
  }) => TextButton.icon(
    key: key,
    onPressed: work.busy || !enabled ? null : action,
    icon: Icon(icon, size: 18),
    label: Text(text),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: work,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 850;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.precision_manufacturing_outlined,
                        size: 22,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Engineering review',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        work.review.hasUnsavedChanges
                            ? 'Local changes'
                            : 'Saved',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Wrap(
                    spacing: 2,
                    children: [
                      button('Open bundle', Icons.folder_open, openBundle),
                      button('Convert CAD', Icons.transform, convert),
                      button('Demo', Icons.view_in_ar_outlined, work.demo),
                      button(
                        'Reload',
                        Icons.refresh,
                        work.reload,
                        enabled: work.root != null,
                      ),
                      button(
                        'Save local',
                        Icons.save_outlined,
                        saveReview,
                        enabled: work.review.document.objects.isNotEmpty,
                      ),
                      button('Load review', Icons.upload_file, loadReview),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      Text(
                        work.session == null
                            ? 'Local review'
                            : 'Shared review connected',
                      ),
                      button(
                        work.session == null ? 'Connect' : 'Change session',
                        Icons.link,
                        connect,
                      ),
                      if (work.session != null) ...[
                        button(
                          'Sync',
                          Icons.sync,
                          work.sync,
                          key: const Key('sync'),
                        ),
                        button('Disconnect', Icons.link_off, work.disconnect),
                      ],
                    ],
                  ),
                ),
                if (work.busy) const LinearProgressIndicator(minHeight: 2),
                if (work.error != null)
                  Container(
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            work.error!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: work.busy ? null : work.retry,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                if (narrow)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: SegmentedButton<bool>(
                      segments: [
                        const ButtonSegment(
                          value: false,
                          label: Text('Model'),
                          icon: Icon(Icons.view_in_ar),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(
                            'Review (${work.review.document.annotations.length})',
                          ),
                          icon: const Icon(Icons.comment_outlined),
                        ),
                      ],
                      selected: {reviewTab},
                      onSelectionChanged: (value) =>
                          setState(() => reviewTab = value.single),
                    ),
                  ),
                Expanded(
                  child: narrow
                      ? IndexedStack(
                          index: reviewTab ? 1 : 0,
                          children: [canvas(), panel()],
                        )
                      : Row(
                          children: [
                            Expanded(child: canvas()),
                            const VerticalDivider(width: 1),
                            SizedBox(width: 360, child: panel()),
                          ],
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          work.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('Metal', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  Widget canvas() => Stack(
    fit: StackFit.expand,
    children: [
      SceneView(
        key: sceneKey,
        controller: work.controller,
        onPointer: work.pointer,
        errorBuilder: (context, issue, retry) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Renderer failed: ${issue.message}'),
              TextButton(onPressed: retry, child: const Text('Retry renderer')),
            ],
          ),
        ),
      ),
      if (work.root == null && !work.busy)
        ZeroState(
          title: 'Choose a CAD review',
          message:
              'Open a converted bundle, or load the IFC housing example to try notes and reloads.',
          actionLabel: 'Load IFC example',
          onAction: work.demo,
        ),
      if (work.root != null)
        Positioned(
          left: 12,
          top: 8,
          right: 12,
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(work.label),
              button('Fit', Icons.center_focus_strong, work.fit),
              button(
                'Isolate',
                Icons.filter_center_focus,
                work.isolate,
                enabled:
                    work.selectedId != null &&
                    work.review.objectFor(work.selectedId!) != null,
              ),
              if (work.review.isolatedIds.isNotEmpty)
                button('Show all', Icons.visibility_outlined, work.showAll),
            ],
          ),
        ),
    ],
  );
  Widget panel() => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      if (work.conflicts.isNotEmpty) ...[
        Text(
          '${work.conflicts.length} shared conflicts',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const Text('Compare each record before choosing what to keep.'),
        for (final conflict in work.conflicts) conflictCard(conflict),
        FilledButton(
          key: const Key('apply-conflicts'),
          onPressed: work.busy || work.choices.length != work.conflicts.length
              ? null
              : work.sync,
          child: const Text('Apply choices and sync'),
        ),
        const Divider(),
      ],
      Text('Source objects', style: Theme.of(context).textTheme.titleSmall),
      if (work.review.document.objects.isEmpty)
        ZeroState(
          title: 'No source objects',
          message: 'A verified bundle connects geometry to its source IDs.',
          actionLabel: 'Open bundle',
          onAction: openBundle,
        ),
      for (final object in work.review.document.objects.values)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          selected: work.selectedId == object.id,
          title: Text(object.label),
          subtitle: Text(
            '${work.review.objectFor(object.id) == null ? 'Unbound · ' : ''}${object.id}',
            maxLines: 2,
          ),
          leading: Icon(
            work.review.objectFor(object.id) == null
                ? Icons.link_off
                : Icons.category_outlined,
            size: 20,
          ),
          onTap: work.busy ? null : () => work.select(object.id),
        ),
      const Divider(),
      Row(
        children: [
          Expanded(
            child: Text(
              'Review notes',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          button(
            'Add note',
            Icons.add_comment_outlined,
            editNote,
            key: const Key('add-note'),
            enabled: work.selectedId != null,
          ),
        ],
      ),
      if (work.selectedId != null)
        Text(
          'Anchor: ${[work.anchor.x, work.anchor.y, work.anchor.z].map((v) => v.toStringAsFixed(2)).join(', ')} m. Tap the model to choose a surface point.',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      if (work.review.document.annotations.isEmpty)
        ZeroState(
          title: 'No review notes',
          message:
              'Select a source object, then add a note at its origin or a picked surface point.',
          actionLabel: 'Add first note',
          onAction: work.selectedId == null || work.busy ? null : editNote,
        ),
      for (final note in work.review.document.annotations.values)
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(note.text),
                const SizedBox(height: 4),
                Text(
                  '${work.review.document.objects[note.objectId]?.label ?? note.objectId}${work.review.objectFor(note.objectId) == null ? ' · Unbound' : ''}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Wrap(
                  children: [
                    button('Edit', Icons.edit_outlined, () => editNote(note)),
                    button(
                      'Locate',
                      Icons.my_location,
                      () => work.select(note.objectId, note.anchor),
                    ),
                    button(
                      'Delete',
                      Icons.delete_outline,
                      () => work.removeNote(note.id),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
    ],
  );
  Widget conflictCard(EngineeringConflict conflict) => Card(
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${conflict.kind.name}: ${conflict.id}',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          for (final value in [
            ('Base', conflict.base),
            ('Local', conflict.local),
            ('Remote', conflict.remote),
          ]) ...[
            const SizedBox(height: 6),
            Text(value.$1, style: Theme.of(context).textTheme.labelSmall),
            SelectableText(
              value.$2 ?? 'Deleted / absent',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          DropdownButtonFormField<EngineeringConflictChoice>(
            key: ValueKey('${conflict.kind}:${conflict.id}:${conflict.remote}'),
            initialValue: work.choices[conflict],
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Keep this record'),
            items: [
              for (final choice in EngineeringConflictChoice.values)
                DropdownMenuItem(value: choice, child: Text(choice.name)),
            ],
            onChanged: work.busy
                ? null
                : (choice) {
                    if (choice != null) work.choose(conflict, choice);
                  },
          ),
        ],
      ),
    ),
  );
}

class CadOptions {
  final String python, script;
  final String? mapping;
  final double? scale;
  const CadOptions(this.python, this.script, this.mapping, this.scale);
}

class CadDialog extends StatefulWidget {
  final String source;
  const CadDialog({super.key, required this.source});
  @override
  State<CadDialog> createState() => _CadDialogState();
}

class _CadDialogState extends State<CadDialog> {
  final python = TextEditingController(
    text: const String.fromEnvironment('ZYREN_CAD_PYTHON'),
  );
  final script = TextEditingController(
    text: const String.fromEnvironment('ZYREN_CAD_CONVERTER'),
  );
  final scale = TextEditingController(text: '0.001');
  String? mapping, error;
  @override
  void dispose() {
    python.dispose();
    script.dispose();
    scale.dispose();
    super.dispose();
  }

  Future<void> choose(TextEditingController controller) async {
    final file = await openFile();
    if (file != null && mounted) controller.text = file.path;
  }

  @override
  Widget build(BuildContext context) {
    final ifc = widget.source.toLowerCase().endsWith('.ifc');
    return AlertDialog(
      title: const Text('Convert CAD'),
      content: SizedBox(
        width: 470,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.source),
              const SizedBox(height: 8),
              const Text(
                'Use the Python environment from tool/cad/requirements.txt and its convert.py script. Each conversion runs in a fresh process.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: python,
                decoration: InputDecoration(
                  labelText: 'Python executable',
                  suffixIcon: IconButton(
                    onPressed: () => choose(python),
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: script,
                decoration: InputDecoration(
                  labelText: 'Converter script',
                  suffixIcon: IconButton(
                    onPressed: () => choose(script),
                    icon: const Icon(Icons.folder_open),
                  ),
                ),
              ),
              if (!ifc) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: scale,
                  decoration: const InputDecoration(
                    labelText: 'Metres per transferred unit',
                  ),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final file = await openFile(
                      acceptedTypeGroups: [
                        const XTypeGroup(
                          label: 'Identity map',
                          extensions: ['json'],
                        ),
                      ],
                    );
                    if (file != null && mounted)
                      setState(() => mapping = file.path);
                  },
                  icon: const Icon(Icons.fingerprint),
                  label: Text(
                    mapping == null
                        ? 'Choose source identity map'
                        : 'Identity map selected',
                  ),
                ),
              ],
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
        FilledButton(
          onPressed: () {
            final units = ifc ? null : double.tryParse(scale.text);
            if (python.text.trim().isEmpty ||
                script.text.trim().isEmpty ||
                !ifc &&
                    (mapping == null ||
                        units == null ||
                        !units.isFinite ||
                        units <= 0)) {
              setState(
                () => error =
                    'Choose the converter files and, for STEP/IGES, a valid scale and identity map.',
              );
              return;
            }
            Navigator.pop(
              context,
              CadOptions(
                python.text.trim(),
                script.text.trim(),
                mapping,
                units,
              ),
            );
          },
          child: const Text('Convert and open'),
        ),
      ],
    );
  }
}
