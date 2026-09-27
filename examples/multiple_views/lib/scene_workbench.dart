import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:flutter_gpu3d/widgets.dart';
import 'package:gpu3d_devtools/gpu3d_devtools.dart';
import 'package:gpu3d_timeline/gpu3d_timeline.dart';
import 'package:gpu3d_tools/gpu3d_tools.dart';

void main() => runApp(
  SceneWorkbenchApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class SceneWorkbenchApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const SceneWorkbenchApp({
    super.key,
    required this.runtime,
    this.presentation = PresentationPolicy.requireNative,
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
    home: _Workbench(runtime: runtime, presentation: presentation),
  );
}

class _Workbench extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const _Workbench({required this.runtime, required this.presentation});
  @override
  State<_Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<_Workbench> {
  final _viewKey = GlobalKey();
  bool _refreshQueued = false;
  late final SceneController _controller;
  final _tools = SceneToolsPlugin();
  final _inspector = SceneDevtoolsPlugin();
  late final SceneTimelinePlugin _timeline;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final List<Mesh> _parts;
  FrameStats? _stats;
  String? _notice;
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
    _timeline = SceneTimelinePlugin(
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
    _controller.use(OrbitControlsPlugin());
    _controller.use(_tools);
    _controller.use(_timeline);
    _controller.use(_inspector);
    _subscriptions.addAll([
      _tools.changes.listen((_) => _refresh()),
      _timeline.changes.listen((_) => _refresh()),
      _controller.frameStats.listen((stats) {
        _stats = stats;
        _refresh();
      }),
      _controller.issues.listen((issue) {
        _notice = issue.message;
        _refresh();
      }),
    ]);
    _controller.status.addListener(_refresh);
    _controller.ready.then(
      (_) {
        if (mounted) {
          _tools.select(_parts.first);
          _refresh();
        }
      },
      onError: (Object error) {
        _notice = '$error';
        _refresh();
      },
    );
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
    _timeline.pause();
    try {
      action();
      _notice = null;
    } catch (error) {
      _notice = '$error';
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
  });

  void _pointer(ScenePointerEvent event) {
    if (!_ready || !_measuring || event.phase != ScenePointerPhase.tap) return;
    final hit = _tools.pick(event.point, _viewport);
    if (hit == null) return;
    if (_anchor == null) {
      _anchor = hit.point;
    } else {
      _tools.measure(_anchor!, hit.point);
      _anchor = null;
      _measuring = false;
    }
    _refresh();
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
      ],
    );
  }

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
      Text(
        '${(_timeline.position.inMilliseconds / 1000).toStringAsFixed(1)} / 3 s',
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
                _measuring
                    ? (_anchor == null
                          ? 'Pick the first surface point'
                          : 'Pick the second surface point')
                    : 'Drag to orbit · Scroll to zoom · Tap to select',
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

  Widget _inspectorPanel() {
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
    final selected = _tools.selected;
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Assembly',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text('${snapshot.nodes.where((node) => node.isMesh).length} parts'),
          ],
        ),
        for (final node in snapshot.nodes)
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
              node.name ?? 'Object ${node.id}',
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
      title: const Text('Scene workbench', style: TextStyle(fontSize: 16)),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Align(alignment: Alignment.centerLeft, child: _toolbar()),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _notice!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
    _controller.status.removeListener(_refresh);
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
