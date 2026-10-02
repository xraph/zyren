import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/widgets.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'workbench_review_store.dart';
import 'review_dialogs.dart';

void main() => runApp(
  SceneWorkbenchApp(
    reviewStore: WorkbenchReviewStore(),
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class SceneWorkbenchApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final EngineeringStore? reviewStore;
  const SceneWorkbenchApp({
    super.key,
    required this.runtime,
    this.presentation = PresentationPolicy.requireNative,
    this.reviewStore,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff78dace),
        brightness: Brightness.dark,
      ),
      visualDensity: VisualDensity.compact,
      useMaterial3: true,
    ),
    home: _Workbench(
      runtime: runtime,
      presentation: presentation,
      reviewStore: reviewStore,
    ),
  );
}

class _Workbench extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final EngineeringStore? reviewStore;
  const _Workbench({
    required this.runtime,
    required this.presentation,
    this.reviewStore,
  });
  @override
  State<_Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<_Workbench> {
  final _viewKey = GlobalKey();
  bool _refreshQueued = false;
  late final SceneController _controller;
  final _tools = SceneToolsPlugin(highlightSelection: false);
  final _outlines = SceneOutlinePlugin(width: 3);
  final _sections = SceneSectionPlugin();
  int _sectionAxis = 0;
  double _sectionOffset = 0;
  bool _sectionFlipped = false;
  final _orbit = OrbitControlsPlugin();
  late final TransformGizmoPlugin _gizmo;
  final _inspector = SceneDevtoolsPlugin();
  late final SceneTimelinePlugin _timeline;
  late final TimelineLayer _lift;
  TimelineEvent? _lastTimelineEvent;
  late final SceneEngineeringPlugin _engineering;
  final _sourceObjects = <String, Object3D>{};
  final _pins = <String, Mesh>{};
  final _pinLeases = <String, Registration>{};
  final _pinGeometry = SphereGeometry(radius: .065);
  bool _reviewTab = false, _annotating = false;
  int? _boundGeneration;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final List<Mesh> _parts;
  FrameStats? _stats;
  String? _notice;
  bool _noticeIsError = false;
  Vec3? _anchor;
  bool _measuring = false;
  ViewportMetrics _viewport = const ViewportMetrics(1, 1);
  bool get _ready =>
      _inspector.isAttached && _controller.status.value is SceneReady;

  @override
  void initState() {
    super.initState();
    _controller = SceneController(
      runtime: widget.runtime,
      options: EngineOptions(presentation: widget.presentation),
      camera: PerspectiveCamera(position: const Vec3(5, 3, 7)),
    );
    _controller.scene.background = Color3.hex(0x14242b);
    final assembly = _controller.scene.add(Group(name: 'Pump assembly'));
    _parts = [
      Mesh(
        BoxGeometry(width: 1.6, height: 1.5, depth: 1.4),
        DiffuseMaterial(color: Color3.hex(0x47b5ad)),
        name: 'Housing',
      ),
      Mesh(
        BoxGeometry(width: 1.3, height: .3, depth: .3),
        DiffuseMaterial(color: Color3.hex(0xb9c5d0)),
        name: 'Shaft',
      )..position = const Vec3(1.2, 0, 0),
      Mesh(
        BoxGeometry(width: .2, height: 1.2, depth: 1.2),
        DiffuseMaterial(color: Color3.hex(0x6f93d0)),
        name: 'Cover',
      )..position = const Vec3(.95, 0, 0),
    ];
    for (final part in _parts) {
      assembly.add(part);
    }
    _sourceObjects.addAll({
      'pump': assembly,
      'housing': _parts[0],
      'shaft': _parts[1],
      'cover': _parts[2],
    });
    final exploded = TimelineClip(
      duration: const Duration(seconds: 3),
      tracks: [
        for (var i = 0; i < _parts.length; i++)
          TransformTrack(_parts[i], [
            TransformKeyframe(Duration.zero, position: _parts[i].position),
            TransformKeyframe(
              const Duration(seconds: 3),
              position: [
                const Vec3(-.5, 0, 0),
                const Vec3(1.4, 0, 0),
                const Vec3(2.4, 0, 0),
              ][i],
            ),
          ]),
      ],
    );
    _lift = TimelineLayer(
      clip: TimelineClip(
        duration: exploded.duration,
        tracks: [
          for (var i = 1; i < _parts.length; i++)
            TransformTrack(_parts[i], [
              for (final key
                  in (exploded.tracks[i] as TransformTrack).keyframes)
                TransformKeyframe(
                  key.time,
                  position: key.position + Vec3(0, i == 1 ? .5 : 1.1, 0),
                  rotation: i == 2
                      ? Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 4)
                      : Quat.identity,
                ),
            ]),
        ],
      ),
      weights: [
        ClipWeight(Duration.zero, 0),
        ClipWeight(const Duration(milliseconds: 1500), 1),
        ClipWeight(exploded.duration, 0),
      ],
    );
    _timeline = SceneTimelinePlugin.mixed(
      duration: exploded.duration,
      base: exploded,
      layers: [_lift],
      markers: [
        TimelineMarker(Duration.zero, id: 'assembled', label: 'Assembled'),
        TimelineMarker(
          const Duration(milliseconds: 1500),
          id: 'separating',
          label: 'Separating',
        ),
        TimelineMarker(exploded.duration, id: 'exploded', label: 'Exploded'),
      ],
    );
    _gizmo = TransformGizmoPlugin(
      size: 2,
      screenSize: 96,
      onDragChanged: (dragging) {
        _orbit.controls?.enabled = !dragging;
        if (dragging) _timeline.pause();
        _refresh();
      },
    );
    _engineering = SceneEngineeringPlugin(
      document: EngineeringDocument(
        id: 'demo-pump-v1',
        objects: [
          EngineeringObject(
            id: 'pump',
            label: 'Pump assembly',
            properties: {'tag': 'DEMO-P-001'},
          ),
          EngineeringObject(
            id: 'housing',
            label: 'Housing',
            properties: {'tag': 'DEMO-HSG-01', 'material': 'Cast iron'},
          ),
          EngineeringObject(
            id: 'shaft',
            label: 'Shaft',
            properties: {'tag': 'DEMO-SFT-01', 'material': 'Steel'},
          ),
          EngineeringObject(
            id: 'cover',
            label: 'Cover',
            properties: {'tag': 'DEMO-CVR-01', 'material': 'Steel'},
          ),
        ],
      ),
      excludeFromIsolation: _gizmo.owns,
    );
    _controller.use(_tools);
    _controller.use(_outlines);
    _controller.use(_sections);
    _controller.use(_gizmo);
    _controller.use(_orbit);
    _controller.use(_timeline);
    _controller.use(_engineering);
    _controller.use(_inspector);
    _subscriptions.addAll([
      _tools.changes.listen((_) => _refresh()),
      _sections.changes.listen((_) => _refresh()),
      _timeline.changes.listen((_) {
        _gizmo.enabled = !_timeline.isPlaying && !_measuring && !_annotating;
        _refresh();
      }),
      _timeline.events.listen((event) {
        _lastTimelineEvent = event;
        _refresh();
      }),
      _engineering.changes.listen((_) {
        _syncPins();
        _refresh();
      }),
      _controller.frameStats.listen((stats) {
        _stats = stats;
        _refresh();
      }),
      _controller.issues.listen((issue) {
        _notice = issue.message;
        _noticeIsError = true;
        _refresh();
      }),
    ]);
    _controller.status.addListener(_statusChanged);
  }

  void _statusChanged() {
    final status = _controller.status.value;
    if (status is SceneReady && status.generation != _boundGeneration) {
      final initial = _boundGeneration == null;
      _boundGeneration = status.generation;
      // A recovered engine has new attachment scopes and picking leases.
      for (final pin in _pins.values) {
        pin.parent?.remove(pin);
      }
      for (final lease in _pinLeases.values) {
        lease.dispose();
      }
      _pins.clear();
      _pinLeases.clear();
      _tools.select(_parts.first);
      _bindReview();
      if (initial && widget.reviewStore != null) {
        unawaited(_loadReview(initial: true));
      }
    }
    _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_refreshQueued) return;
      _refreshQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshQueued = false;
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _edit(void Function() action) {
    _gizmo.cancel();
    _timeline.pause();
    try {
      action();
      _notice = null;
    } catch (error) {
      _notice = '$error';
      _noticeIsError = true;
    }
    _refresh();
  }

  void _seek(double value) => _edit(() {
    _tools.clearHistory();
    _timeline.seek(
      Duration(
        microseconds: (value * _timeline.duration.inMicroseconds).round(),
      ),
    );
    _lastTimelineEvent = null;
  });

  void _pointer(ScenePointerEvent event) {
    if (!_ready ||
        (!_measuring && !_annotating) ||
        event.phase != ScenePointerPhase.tap) {
      return;
    }
    final hit = _tools.pick(event.point, _viewport);
    if (hit == null) return;
    if (_annotating) {
      final id = _engineering.idFor(hit.object);
      if (id == null) {
        _notice = 'Add metadata for this part before attaching a note.';
        _noticeIsError = false;
        _refresh();
        return;
      }
      _annotating = false;
      _gizmo.enabled = true;
      unawaited(
        _noteDialog(
          objectId: id,
          anchor: _engineering.localAnchor(id, hit.point),
        ),
      );
      return;
    }
    if (_anchor == null) {
      _anchor = hit.point;
    } else {
      _tools.measure(_anchor!, hit.point);
      _anchor = null;
      _measuring = false;
      _gizmo.enabled = true;
    }
    _refresh();
  }

  void _bindReview() {
    for (final entry in _sourceObjects.entries) {
      if (_engineering.document.objects.containsKey(entry.key)) {
        _engineering.bind(entry.key, entry.value);
      }
    }
    _syncPins();
  }

  void _syncPins() {
    if (!_engineering.isAttached || _controller.isDisposed) return;
    for (final id in _pins.keys.toList()) {
      final note = _engineering.document.annotations[id];
      if (note == null || _engineering.objectFor(note.objectId) == null) {
        final pin = _pins.remove(id)!;
        pin.parent?.remove(pin);
        _pinLeases.remove(id)?.dispose();
      }
    }
    for (final note in _engineering.document.annotations.values) {
      final object = _engineering.objectFor(note.objectId);
      if (object == null) continue;
      final pin = _pins.putIfAbsent(note.id, () {
        final pin = Mesh(
          _pinGeometry,
          UnlitMaterial(color: Color3.hex(0xff8ec3)),
          name: 'Review pin',
        )..outlineEnabled = false;
        _pinLeases[note.id] = _tools.excludeFromPicking(pin);
        return pin;
      });
      object.add(pin);
      pin.position = note.anchor;
    }
  }

  Future<void> _saveReview() async {
    try {
      await _engineering.save(widget.reviewStore!);
      if (!mounted) return;
      _notice = _engineering.hasUnsavedChanges
          ? 'Saved. Newer edits are still unsaved.'
          : 'Review saved.';
      _noticeIsError = false;
    } catch (error) {
      if (!mounted) return;
      _notice = 'Could not save review: $error';
      _noticeIsError = true;
    }
    _refresh();
  }

  Future<void> _loadReview({bool initial = false}) async {
    if (!initial && _engineering.hasUnsavedChanges) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reload saved review?'),
          content: const Text('This discards unsaved metadata and notes.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reload'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    try {
      final found = await _engineering.load(widget.reviewStore!);
      if (!mounted) return;
      _bindReview();
      _notice = initial
          ? null
          : found
          ? 'Review reloaded.'
          : 'No saved review yet. Current edits were kept.';
      _noticeIsError = false;
    } catch (error) {
      if (!mounted) return;
      _notice = 'Could not load review: $error';
      _noticeIsError = true;
    }
    _refresh();
  }

  Future<void> _metadataDialog() async {
    final selected = _tools.selected;
    if (selected == null) return;
    final source = _sourceObjects.entries
        .where((entry) => identical(entry.value, selected))
        .firstOrNull;
    if (source == null) return;
    final before =
        _engineering.document.objects[source.key] ??
        EngineeringObject(id: source.key, label: selected.name ?? source.key);
    final record = await showDialog<EngineeringObject>(
      context: context,
      builder: (_) => ReviewMetadataDialog(record: before),
    );
    if (record == null || !mounted) return;
    _edit(() {
      _engineering.putObject(record);
      _engineering.bind(record.id, selected);
    });
  }

  void _startNote() {
    _edit(() {
      _annotating = !_annotating;
      _measuring = false;
      _anchor = null;
      _gizmo.enabled = !_annotating;
    });
  }

  Future<void> _noteDialog({
    EngineeringAnnotation? note,
    String? objectId,
    Vec3? anchor,
  }) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => ReviewNoteDialog(text: note?.text ?? ''),
    );
    if (text == null || !mounted) return;
    var id = note?.id;
    if (id == null) {
      var next = 1;
      while (_engineering.document.annotations.containsKey('note-$next')) {
        next++;
      }
      id = 'note-$next';
    }
    _edit(
      () => _engineering.putAnnotation(
        EngineeringAnnotation(
          id: id!,
          objectId: note?.objectId ?? objectId!,
          text: text,
          anchor: note?.anchor ?? anchor!,
        ),
      ),
    );
    _reviewTab = true;
    _refresh();
  }

  Widget _reviewPanel() {
    final selected = _tools.selected;
    final id = selected == null ? null : _engineering.idFor(selected);
    final record = _engineering.document.objects[id];
    final available = !_engineering.isBusy;
    final notes = _engineering.document.annotations.values;
    return ListView(
      key: const ValueKey('review-list'),
      padding: const EdgeInsets.all(8),
      children: [
        Wrap(
          spacing: 2,
          children: [
            _button(
              'Edit metadata',
              Icons.edit_note,
              available && selected != null
                  ? () => unawaited(_metadataDialog())
                  : null,
            ),
            _button(
              _annotating ? 'Cancel note' : 'Add surface note',
              Icons.add_comment_outlined,
              available ? _startNote : null,
            ),
            _button(
              'Isolate selected',
              Icons.filter_center_focus,
              available && id != null
                  ? () => _edit(() => _engineering.isolate({id}))
                  : null,
            ),
            _button(
              'Restore visibility',
              Icons.layers_outlined,
              _engineering.isolatedIds.isNotEmpty
                  ? () => _edit(_engineering.restoreVisibility)
                  : null,
            ),
          ],
        ),
        if (record == null)
          ZeroState(
            title: selected == null ? 'Select a part' : 'No metadata',
            message: 'Choose a part and add its engineering record.',
            actionLabel: selected == null ? 'Select housing' : 'Add metadata',
            onAction: () => selected == null
                ? _tools.select(_parts.first)
                : unawaited(_metadataDialog()),
          )
        else ...[
          Text(
            record.label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          SelectableText(
            'ID: ${record.id}',
            style: const TextStyle(fontSize: 12),
          ),
          for (final property in record.properties.entries)
            Text(
              '${property.key}: ${property.value ?? '-'}',
              style: const TextStyle(fontSize: 12),
            ),
        ],
        if (_engineering.isolatedIds.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Isolation active', style: TextStyle(fontSize: 12)),
          ),
        const Divider(height: 16),
        Text(
          'Notes (${notes.length})',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (notes.isEmpty)
          ZeroState(
            title: 'No review notes',
            message: 'Pick a surface to attach a note to that part.',
            actionLabel: 'Add surface note',
            onAction: available ? _startNote : null,
          ),
        for (final note in notes)
          ListTile(
            key: ValueKey('annotation-${note.id}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              note.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${_engineering.document.objects[note.objectId]!.label}${_engineering.objectFor(note.objectId) == null ? ' (not in this scene)' : ''}',
            ),
            onTap: available ? () => unawaited(_noteDialog(note: note)) : null,
            leading: IconButton(
              tooltip: 'Select annotated part',
              icon: const Icon(Icons.location_on_outlined, size: 18),
              onPressed: _engineering.objectFor(note.objectId) == null
                  ? null
                  : () => _tools.select(_engineering.objectFor(note.objectId)),
            ),
            trailing: IconButton(
              tooltip: 'Delete note ${note.id}',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: available
                  ? () => _engineering.removeAnnotation(note.id)
                  : null,
            ),
          ),
      ],
    );
  }

  Widget _button(String label, IconData icon, VoidCallback? action) =>
      IconButton(
        tooltip: label,
        onPressed: action,
        icon: Icon(icon, size: 20),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      );

  Widget _toolbar() {
    final selected = _tools.selected;
    final editable = _ready && selected != null;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      children: [
        DropdownButton<GizmoMode>(
          key: const ValueKey('gizmo-mode'),
          value: _gizmo.mode,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: GizmoMode.translate, child: Text('Move')),
            DropdownMenuItem(value: GizmoMode.rotate, child: Text('Rotate')),
            DropdownMenuItem(value: GizmoMode.scale, child: Text('Scale')),
          ],
          onChanged: _ready ? (mode) => _edit(() => _gizmo.mode = mode!) : null,
        ),
        Tooltip(
          message: _gizmo.mode == GizmoMode.scale
              ? 'Scaling uses local axes'
              : 'Transform coordinate space',
          child: DropdownButton<GizmoSpace>(
            key: const ValueKey('gizmo-space'),
            value: _gizmo.effectiveSpace,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: GizmoSpace.local, child: Text('Local')),
              DropdownMenuItem(value: GizmoSpace.world, child: Text('World')),
            ],
            onChanged: _ready && _gizmo.mode != GizmoMode.scale
                ? (space) => _edit(() => _gizmo.space = space!)
                : null,
          ),
        ),
        IconButton(
          tooltip: 'Snap: 0.25 units / 15° / 10%',
          isSelected: _gizmo.snapEnabled,
          icon: const Icon(Icons.grid_4x4, size: 20),
          onPressed: _ready
              ? () => setState(() => _gizmo.snapEnabled = !_gizmo.snapEnabled)
              : null,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
        _button(
          'Move -X',
          Icons.arrow_back,
          editable
              ? () => _edit(
                  () => _tools.transform(
                    selected,
                    position: selected.position - const Vec3(.25, 0, 0),
                    grid: .25,
                  ),
                )
              : null,
        ),
        _button(
          'Move +X',
          Icons.arrow_forward,
          editable
              ? () => _edit(
                  () => _tools.transform(
                    selected,
                    position: selected.position + const Vec3(.25, 0, 0),
                    grid: .25,
                  ),
                )
              : null,
        ),
        _button(
          'Rotate Y',
          Icons.rotate_right,
          editable
              ? () => _edit(
                  () => _tools.transform(
                    selected,
                    rotation:
                        selected.quaternion *
                        Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 12),
                  ),
                )
              : null,
        ),
        _button(
          'Scale up',
          Icons.open_in_full,
          editable
              ? () => _edit(
                  () => _tools.transform(selected, scale: selected.scale * 1.1),
                )
              : null,
        ),
        _button(
          'Undo',
          Icons.undo,
          _ready && _tools.canUndo ? () => _edit(_tools.undo) : null,
        ),
        _button(
          'Redo',
          Icons.redo,
          _ready && _tools.canRedo ? () => _edit(_tools.redo) : null,
        ),
        _button(
          _measuring ? 'Cancel measurement' : 'Measure two points',
          Icons.straighten,
          _ready
              ? () {
                  _timeline.pause();
                  _measuring = !_measuring;
                  _annotating = false;
                  _gizmo.enabled = !_measuring;
                  _anchor = null;
                  _refresh();
                }
              : null,
        ),
        _button(
          'Clear measurements',
          Icons.layers_clear,
          _tools.measurements.isNotEmpty
              ? () => _tools.clearMeasurements()
              : null,
        ),
        IconButton(
          tooltip: 'Section view',
          isSelected: _sections.isActive,
          icon: const Icon(Icons.content_cut, size: 20),
          onPressed: _ready
              ? () => _edit(() {
                  if (_sections.isActive) {
                    _sections.clear();
                  } else {
                    _applySection();
                  }
                })
              : null,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        ),
      ],
    );
  }

  void _applySection() {
    final normal = [
      const Vec3(1, 0, 0),
      const Vec3(0, 1, 0),
      const Vec3(0, 0, 1),
    ][_sectionAxis];
    final plane = ClippingPlane(normal: normal, offset: _sectionOffset);
    _sections.setPlanes([_sectionFlipped ? plane.flipped : plane]);
  }

  Widget _sectionBar() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      children: [
        DropdownButton<int>(
          key: const ValueKey('section-axis'),
          value: _sectionAxis,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: 0, child: Text('Cut X')),
            DropdownMenuItem(value: 1, child: Text('Cut Y')),
            DropdownMenuItem(value: 2, child: Text('Cut Z')),
          ],
          onChanged: _ready
              ? (value) => _edit(() {
                  _sectionAxis = value!;
                  _applySection();
                })
              : null,
        ),
        Expanded(
          child: Slider(
            key: const ValueKey('section-offset'),
            min: -2,
            max: 2,
            divisions: 80,
            value: _sectionOffset,
            label: _sectionOffset.toStringAsFixed(2),
            semanticFormatterCallback: (value) =>
                'Section offset ${value.toStringAsFixed(2)} scene units',
            onChanged: _ready
                ? (value) => _edit(() {
                    _sectionOffset = value;
                    _applySection();
                  })
                : null,
          ),
        ),
        SizedBox(
          width: 42,
          child: Text(
            _sectionOffset.toStringAsFixed(2),
            textAlign: TextAlign.end,
          ),
        ),
        _button(
          'Flip section',
          Icons.flip,
          _ready
              ? () => _edit(() {
                  _sectionFlipped = !_sectionFlipped;
                  _applySection();
                })
              : null,
        ),
        _button(
          'Clear section',
          Icons.close,
          _ready ? () => _edit(_sections.clear) : null,
        ),
      ],
    ),
  );

  Widget _playback() => Row(
    children: [
      _button(
        _timeline.isPlaying ? 'Pause' : 'Play',
        _timeline.isPlaying ? Icons.pause : Icons.play_arrow,
        _ready
            ? () {
                if (_timeline.isPlaying) {
                  _timeline.pause();
                } else {
                  _annotating = _measuring = false;
                  _gizmo.enabled = false;
                  _tools.clearHistory();
                  _timeline.play();
                }
              }
            : null,
      ),
      Expanded(
        child: Slider(
          key: const ValueKey('timeline'),
          label:
              '${(_timeline.position.inMilliseconds / 1000).toStringAsFixed(1)} s',
          value:
              _timeline.position.inMicroseconds /
              _timeline.duration.inMicroseconds,
          onChanged: _ready ? _seek : null,
        ),
      ),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${(_timeline.position.inMilliseconds / 1000).toStringAsFixed(1)} / 3 s',
          ),
          Tooltip(
            message:
                'Lift clip weight. Peaks halfway through the assembly sequence.',
            child: Text(
              'Lift ${(_lift.weightAt(_timeline.position) * 100).round()}%',
              key: const ValueKey('timeline-mix'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          if (_lastTimelineEvent case final event?)
            Tooltip(
              message:
                  'Last marker: ${event.marker.label} at '
                  '${(event.marker.time.inMilliseconds / 1000).toStringAsFixed(1)} s',
              child: Text(
                event.marker.label!,
                key: const ValueKey('timeline-event'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
      _button('Reset pose', Icons.restart_alt, _ready ? () => _seek(0) : null),
    ],
  );

  Widget _canvas() => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = ViewportMetrics(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        fit: StackFit.expand,
        children: [
          SceneView(
            key: _viewKey,
            controller: _controller,
            onPointer: _pointer,
            loadingBuilder: (_) =>
                const Center(child: CircularProgressIndicator()),
            errorBuilder: (_, issue, retry) => ZeroState(
              title: 'Scene unavailable',
              message: issue.message,
              actionLabel: 'Retry renderer',
              onAction: retry,
            ),
          ),
          IgnorePointer(
            child: CustomPaint(
              painter: _MeasurementsPainter(
                _tools.measurements,
                _controller.camera,
              ),
            ),
          ),
          Positioned(
            left: 10,
            top: 8,
            child: IgnorePointer(
              child: Text(
                _annotating
                    ? 'Pick a surface for the review note'
                    : _measuring
                    ? (_anchor == null
                          ? 'Pick the first surface point'
                          : 'Pick the second surface point')
                    : _gizmo.unavailableReason ??
                          (_gizmo.isDragging
                              ? 'Drag ${_gizmo.activeHandle!.label} · Esc cancels'
                              : _gizmo.mode == GizmoMode.translate
                              ? 'Drag an axis or plane · Drag space to orbit'
                              : 'Drag an axis · Drag space to orbit'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
        ],
      );
    },
  );

  String _vector(Vec3 value) =>
      '${value.x.toStringAsFixed(2)}, ${value.y.toStringAsFixed(2)}, ${value.z.toStringAsFixed(2)}';

  Widget _inspectorPanel() => Column(
    children: [
      SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => setState(() => _reviewTab = false),
                child: Text(
                  'Assembly',
                  style: TextStyle(color: _reviewTab ? Colors.white60 : null),
                ),
              ),
            ),
            Expanded(
              child: TextButton(
                key: const ValueKey('review-tab'),
                onPressed: () => setState(() => _reviewTab = true),
                child: Text(
                  'Review',
                  style: TextStyle(color: _reviewTab ? null : Colors.white60),
                ),
              ),
            ),
            if (_ready)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${_parts.length} parts',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      Expanded(child: _reviewTab && _ready ? _reviewPanel() : _assemblyPanel()),
    ],
  );

  Widget _assemblyPanel() {
    final status = _controller.status.value;
    if (status is SceneFailed) {
      return ZeroState(
        title: 'Inspector unavailable',
        message: status.issue.message,
        actionLabel: 'Retry',
        onAction: () => unawaited(_controller.retry()),
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final snapshot = _inspector.snapshot();
    final nodes = snapshot.nodes.where(
      (node) =>
          !_gizmo.owns(_inspector.objectFor(node.id)!) &&
          !_pins.containsValue(_inspector.objectFor(node.id)),
    );
    final selected = _tools.selected;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        for (final node in nodes)
          ListTile(
            key: ValueKey('part-${node.name}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.only(
              left: 4 + node.depth * 12.0,
              right: 4,
            ),
            leading: Icon(
              node.isMesh ? Icons.view_in_ar : Icons.account_tree_outlined,
              size: 18,
            ),
            title: Text(
              _engineering
                      .document
                      .objects[_engineering.idFor(
                        _inspector.objectFor(node.id)!,
                      )]
                      ?.label ??
                  node.name ??
                  'Object ${node.id}',
              overflow: TextOverflow.ellipsis,
            ),
            selected: identical(_inspector.objectFor(node.id), selected),
            onTap: () => _tools.select(_inspector.objectFor(node.id)),
            trailing: IconButton(
              tooltip: node.visible ? 'Hide ${node.name}' : 'Show ${node.name}',
              icon: Icon(
                node.visible
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
              onPressed: () => _edit(() {
                final object = _inspector.objectFor(node.id)!;
                object.visible = !object.visible;
              }),
            ),
          ),
        const Divider(height: 12),
        if (selected == null)
          ZeroState(
            title: 'Select a part',
            message: 'Pick a surface or choose a part in the assembly.',
            actionLabel: 'Select housing',
            onAction: () => _tools.select(_parts.first),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  selected.name ?? 'Selected object',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _button(
                'Clear selection',
                Icons.close,
                () => _tools.select(null),
              ),
            ],
          ),
          SelectableText(
            'Position  ${_vector(selected.position)}\nScale      ${_vector(selected.scale)}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
        const Divider(height: 12),
        Text(
          '${_stats?.drawCalls ?? 0} draws · ${_stats?.triangles ?? 0} triangles',
          style: const TextStyle(fontSize: 12),
        ),
        Text(
          'GPU time: ${_stats?.gpuTime == null ? 'unavailable' : '${_stats!.gpuTime!.inMicroseconds} µs'}',
          style: const TextStyle(fontSize: 12),
        ),
        Text(
          'Resident payload: ${_stats?.residentBytes == null ? 'unavailable' : '${_stats!.residentBytes} B'}',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 6),
        Text(
          '${_controller.pluginIds.length} plugins · ${_inspector.capabilities.name}',
          style: const TextStyle(fontSize: 12),
        ),
        for (final measurement in _tools.measurements)
          Text('${measurement.distance.toStringAsFixed(3)} scene units'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 44,
      title: const Text(
        'Scene workbench',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 16),
      ),
      actions: [
        Center(
          child: Text(
            widget.reviewStore == null
                ? 'Session'
                : _engineering.isBusy
                ? 'Working'
                : _engineering.hasUnsavedChanges
                ? 'Unsaved'
                : 'Saved',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        _button(
          'Save review',
          Icons.save_outlined,
          _ready && widget.reviewStore != null && !_engineering.isBusy
              ? () => unawaited(_saveReview())
              : null,
        ),
        _button(
          'Reload review',
          Icons.folder_open,
          _ready && widget.reviewStore != null && !_engineering.isBusy
              ? () => unawaited(_loadReview())
              : null,
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Align(alignment: Alignment.centerLeft, child: _toolbar()),
          ),
          if (_sections.isActive) _sectionBar(),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _notice!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _noticeIsError
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth >= 700
                  ? Row(
                      children: [
                        Expanded(child: _canvas()),
                        SizedBox(width: 280, child: _inspectorPanel()),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(child: _canvas()),
                        SizedBox(height: 190, child: _inspectorPanel()),
                      ],
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: _playback(),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _controller.status.removeListener(_statusChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _controller.dispose();
    super.dispose();
  }
}

class _MeasurementsPainter extends CustomPainter {
  final List<SceneMeasurement> measurements;
  final Camera camera;
  _MeasurementsPainter(this.measurements, this.camera);
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xfff2bd65)
      ..strokeWidth = 2;
    for (final measurement in measurements) {
      final a = camera.projectPoint(measurement.start, size.aspectRatio),
          b = camera.projectPoint(measurement.end, size.aspectRatio);
      if (a.z < 0 || a.z > 1 || b.z < 0 || b.z > 1) continue;
      Offset point(Vec3 value) => Offset(
        (value.x + 1) * size.width / 2,
        (1 - value.y) * size.height / 2,
      );
      final start = point(a), end = point(b);
      canvas.drawLine(start, end, paint);
      canvas.drawCircle(start, 4, paint);
      canvas.drawCircle(end, 4, paint);
      final text = TextPainter(
        text: TextSpan(
          text: '${measurement.distance.toStringAsFixed(2)} units',
          style: const TextStyle(
            color: Colors.white,
            backgroundColor: Color(0xdd14242b),
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, (start + end) / 2 + const Offset(6, 6));
    }
  }

  @override
  bool shouldRepaint(covariant _MeasurementsPainter oldDelegate) => true;
}
