import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_inspector/zyren_inspector.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/agents.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'package:zyren_tools/zyren_tools.dart';

/// Flutter composition lives in the host; documents and reconstruction are Dart.
class StudioEditor extends StatefulWidget {
  final StudioDocument document;
  final StudioStore store;
  final String saveLocation;
  final bool initiallySaved;
  final SceneRuntime runtime;
  final Set<String> agentScopes;
  final bool enableAgentTransport;
  final Widget Function(SceneController)? viewportBuilder;
  const StudioEditor({
    super.key,
    required this.document,
    required this.store,
    required this.saveLocation,
    this.initiallySaved = false,
    this.runtime = const SceneRuntime.nativeMetal(),
    this.agentScopes = const {},
    this.enableAgentTransport = false,
    this.viewportBuilder,
  });
  @override
  State<StudioEditor> createState() => StudioEditorState();
}

class StudioEditorState extends State<StudioEditor> {
  late StudioScene _scene;
  late AgentRegistry _agents;
  late StudioAgentProvider _agentProvider;
  late StudioCommands _commands;
  DevtoolsServer? _agentServer;
  late SceneDiagnostics _diagnostics;
  final _providerGaps = <String>[];
  AgentRegistry get agents => _agents;
  StudioAgentProvider get agentProvider => _agentProvider;
  final _canvasKey = GlobalKey();
  int _uiRevision = 0;
  int _commandUiRevision = 0;
  String _activePanel = 'viewport';
  String? _hoveredId;
  ViewportPoint? _pointer;
  PresentationSample? _presented;
  bool _modalOpen = false;
  Size _viewportSize = Size.zero;
  double _dpr = 1;

  late SceneController _controller;
  late TransformGizmoPlugin _gizmo;
  late OrbitControlsPlugin _orbit;
  late SceneTimelinePlugin _timeline;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  String? _saved, _notice;
  bool _busy = false, _error = false, _refreshQueued = false;
  StudioCamera? _previewCamera;
  int? _boundGeneration;
  int _session = 0;
  bool get _ready => _controller.status.value is SceneReady;
  bool get _editing =>
      _ready && !_busy && !_modalOpen && _previewCamera == null;
  Object3D? get _selected => _scene.idFor(_scene.tools.selected) == null
      ? null
      : _scene.tools.selected;
  bool get _dirty {
    try {
      return _saved != _scene.capture().encode();
    } catch (_) {
      return true;
    }
  }

  @override
  void initState() {
    super.initState();
    _install(widget.document);
    if (widget.initiallySaved) _saved = widget.document.encode();
  }

  void _install(StudioDocument document) {
    _scene = StudioScene(document);
    _boundGeneration = null;
    _hoveredId = null;
    _pointer = null;
    _presented = null;
    _orbit = OrbitControlsPlugin();
    _gizmo = TransformGizmoPlugin(
      screenSize: 80,
      onDragChanged: (active) => _orbit.controls?.enabled = !active,
    );
    _scene.registerHelper(_gizmo.owns);
    final pose = document.camera;
    _timeline = SceneTimelinePlugin(
      duration: const Duration(seconds: 3),
      tracks: [
        CameraTrack(_scene.camera, [
          CameraKeyframe(
            Duration.zero,
            position: pose.position,
            target: pose.target,
            up: pose.up,
          ),
          CameraKeyframe(
            const Duration(seconds: 3),
            position: pose.position + const Vec3(2, 1, 0),
            target: pose.target,
            up: pose.up,
          ),
        ]),
      ],
    );
    _controller = SceneController(
      scene: _scene.scene,
      camera: _scene.camera,
      runtime: widget.runtime,
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
    );
    _controller.use(_scene.tools);
    _controller.use(SceneOutlinePlugin());
    _controller.use(_gizmo);
    _controller.use(_orbit);
    _controller.use(_timeline);
    _controller.use(_scene.engineering);
    final inspector = _controller.use(SceneDevtoolsPlugin());
    _diagnostics = SceneDiagnostics(inspector);
    _commands = StudioCommands(
      scene: _scene,
      sessionId: 'studio-${DateTime.now().microsecondsSinceEpoch}',
      isAvailable: () => _editing,
      isAllowed: (kind) => widget.agentScopes.contains(
        kind == StudioCommandKind.select ? 'studio.select' : 'studio.edit',
      ),
    );
    _agents = AgentRegistry(grantedScopes: widget.agentScopes);
    _agentProvider = StudioAgentProvider(
      commands: _commands,
      screenContext: _screenContext,
      hostRevision: () => _commandUiRevision,
    );
    _agents.register(_agentProvider);
    _providerGaps.clear();
    try {
      _agents.register(
        DiagnosticsAgentProvider(
          diagnostics: _diagnostics,
          inspector: inspector,
          instanceId: 'main',
        ),
      );
    } on ArgumentError {
      _providerGaps.add(
        'Diagnostics registry adapter schema is unsupported; original diagnostic tools remain available through devtools.',
      );
    }
    _agents.register(
      AgentViewportProvider(
        sceneId: _commands.sessionId,
        documentId: document.id,
        instanceId: 'main',
        scene: _scene.scene,
        camera: () => _scene.camera,
        viewport: () => ViewportMetrics(
          _viewportSize.width,
          _viewportSize.height,
          devicePixelRatio: _dpr,
        ),
        hostState: _screenContext,
        presentedFrame: () => _presented == null
            ? null
            : AgentPresentedFrame(id: _presented!.frame.frameId.toString()),
        metadata: (object) {
          final id = _scene.idFor(object);
          final node = document.nodes
              .where((node) => node.id == id)
              .firstOrNull;
          return AgentObjectMetadata(
            sourceId: node?.sourceId,
            semanticType: node?.kind.name ?? 'editor-helper',
            owningPlugin: 'zyren.studio',
            properties: {
              'studio.nodeId': id,
              'studio.selected': identical(object, _scene.tools.selected),
              'studio.hovered': id != null && id == _hoveredId,
            },
            provenance: {'documentId': document.id, 'sourceId': node?.sourceId},
            actions: id == null
                ? const []
                : [
                    'zyren.studio/${_commands.sessionId}/select',
                    'zyren.studio/${_commands.sessionId}/transform',
                  ],
          );
        },
      ),
    );
    if (widget.enableAgentTransport && kDebugMode) {
      unawaited(_startAgentTransport(_agents, _diagnostics));
    }
    _controller.status.addListener(_statusChanged);
    _subscriptions.addAll([
      _controller.issues.listen(_diagnostics.recordIssue),
      _controller.presentations.listen((sample) {
        _presented = sample;
        _uiRevision++;
      }),
      _scene.tools.changes.listen((_) => _refresh()),
      _scene.scene.changes.listen((_) => _refresh()),
      _scene.camera.changes.listen((_) => _refresh()),
      _scene.engineering.changes.listen((_) => _refresh()),
      _timeline.changes.listen((_) => _refresh()),
    ]);
  }

  void _statusChanged() {
    final status = _controller.status.value;
    if (status is SceneReady && status.generation != _boundGeneration) {
      _boundGeneration = status.generation;
      _scene.bindReview();
    }
    _refresh();
  }

  void _refresh() {
    if (!mounted || _refreshQueued) return;
    _uiRevision++;
    _refreshQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _refreshQueued = false;
      if (mounted) setState(() {});
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  Future<void> _startAgentTransport(
    AgentRegistry registry,
    SceneDiagnostics diagnostics,
  ) async {
    try {
      final server = await DevtoolsServer.start(diagnostics, agents: registry);
      if (!mounted || !identical(registry, _agents)) {
        await server.close();
        return;
      }
      _agentServer = server;
      debugPrint(
        'ZYREN_STUDIO_AGENTS ${jsonEncode({'endpoint': server.endpoint.toString(), 'token': server.token})}',
      );
    } catch (_) {
      if (mounted && identical(registry, _agents)) {
        setState(() {
          _notice =
              'Agent transport could not start. Check local socket permissions.';
          _error = true;
        });
      }
    }
  }

  void _release() {
    final server = _agentServer;
    _agentServer = null;
    if (server != null) unawaited(server.close());
    _agents.dispose();
    _commands.dispose();
    _controller.status.removeListener(_statusChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _controller.dispose();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _edit(void Function() action) {
    _commandUiRevision++;
    try {
      action();
      setState(() {
        _notice = null;
        _error = false;
      });
    } catch (error) {
      setState(() {
        _notice = '$error';
        _error = true;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      _gizmo.cancel();
      final document = _scene.capture();
      final encoded = document.encode();
      await widget.store.write(document);
      if (!mounted) return;
      setState(() {
        _saved = encoded;
        _notice = 'Scene saved';
        _error = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = 'Save failed: $error';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    if (_dirty) {
      setState(() {
        _modalOpen = true;
        _uiRevision++;
      });
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reload saved scene?'),
          content: const Text(
            'Your unsaved edits will be replaced by the last saved scene.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reload saved'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      setState(() {
        _modalOpen = false;
        _uiRevision++;
      });
      if (discard != true) return;
    }
    setState(() => _busy = true);
    try {
      final document = await widget.store.read();
      if (!mounted) return;
      if (document == null) {
        setState(() {
          _notice = 'No saved scene yet. Save your scene first.';
          _error = false;
        });
        return;
      }
      // Validate reconstruction before retiring the active controller.
      StudioScene(document).capture();
      _release();
      _install(document);
      setState(() {
        _session++;
        _saved = document.encode();
        _notice = 'Saved scene reloaded';
        _error = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = 'Reload failed: $error';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _preview() => _edit(() {
    if (_previewCamera == null) {
      _gizmo.cancel();
      _previewCamera = StudioCamera.capture(_scene.camera);
      _gizmo.enabled = false;
      _orbit.controls?.enabled = false;
      _timeline.seek(Duration.zero);
      _timeline.play();
    } else {
      _timeline.pause();
      final camera = _previewCamera!;
      _scene.camera.batch(() {
        _scene.camera.position = camera.position;
        _scene.camera.target = camera.target;
        _scene.camera.up = camera.up;
      });
      _previewCamera = null;
      _gizmo.enabled = true;
      _orbit.controls?.enabled = true;
    }
  });

  Widget _button(String label, IconData icon, VoidCallback? action) =>
      TextButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 18),
        label: Text(label),
      );

  Widget _inspector() => Column(
    children: [
      if (_selected case final selected?)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'X ${selected.position.x.toStringAsFixed(2)}  Y ${selected.position.y.toStringAsFixed(2)}  Z ${selected.position.z.toStringAsFixed(2)}',
                key: const ValueKey('selection-position'),
              ),
              _button(
                'X +0.25',
                Icons.add,
                _editing
                    ? () => _edit(
                        () => _scene.tools.transform(
                          selected,
                          position: selected.position + const Vec3(.25, 0, 0),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      Expanded(
        child: SceneInspector(
          controller: _controller,
          selectedObject: _scene.tools.selected,
          onSelectionChanged: _editing
              ? (object) => _edit(
                  () => _scene.tools.select(
                    _scene.idFor(object) == null ? null : object,
                  ),
                )
              : null,
        ),
      ),
    ],
  );

  Widget _canvasContents() => Stack(
    fit: StackFit.expand,
    children: [
      widget.viewportBuilder?.call(_controller) ??
          SceneView(
            key: ValueKey(_session),
            controller: _controller,
            onPointer: _observePointer,
            loadingBuilder: (_) =>
                const Center(child: CircularProgressIndicator()),
            errorBuilder: (_, issue, retry) => ZeroState(
              title: 'Renderer unavailable',
              message: issue.message,
              actionLabel: 'Retry renderer',
              onAction: retry,
            ),
          ),
      if (_scene.objects.isEmpty && _ready)
        ZeroState(
          title: 'Your scene is empty',
          message:
              'Reload a saved document with authored groups or boxes to start editing.',
          actionLabel: 'Reload saved scene',
          onAction: !_busy ? _reload : null,
        ),
    ],
  );

  void _observePointer(ScenePointerEvent event) {
    _activePanel = 'viewport';
    _pointer = event.point;
    if (_ready &&
        !_busy &&
        !_modalOpen &&
        _viewportSize.width > 0 &&
        _viewportSize.height > 0) {
      _hoveredId = _scene.idFor(
        _scene.tools
            .pick(
              event.point,
              ViewportMetrics(_viewportSize.width, _viewportSize.height),
            )
            ?.object,
      );
    } else {
      _hoveredId = null;
    }
    _uiRevision++;
  }

  Map<String, Object?> _screenContext() {
    final box = _canvasKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box?.hasSize == true
        ? box!.localToGlobal(Offset.zero)
        : null;
    final presented = _presented;
    return {
      'sceneId': _commands.sessionId,
      'documentId': _scene.document.id,
      'viewportId': 'main',
      'activePanel': _activePanel,
      'sceneRevision': _scene.scene.revision,
      'uiRevision': _uiRevision,
      'cameraId': 'main-camera',
      'cameraRevision': _scene.camera.revision,
      'camera': StudioCamera.capture(_scene.camera).toJson(),
      'projection': 'perspective',
      'toolMode': _gizmo.mode.name,
      'coordinateSpace': 'viewport-local-logical-pixels-top-left',
      'logicalRect': {
        'x': origin?.dx,
        'y': origin?.dy,
        'width': _viewportSize.width,
        'height': _viewportSize.height,
      },
      'devicePixelRatio': _dpr,
      'selectedId': _scene.idFor(_scene.tools.selected),
      'hoveredId': _hoveredId,
      'pointer': _pointer == null ? null : {'x': _pointer!.x, 'y': _pointer!.y},
      'pointerEvidence': 'pointer location, not eye gaze',
      'hoverEvidence':
          'CPU triangle geometry; texture alpha and shader displacement are not evaluated',
      'blockingOverlays': [
        if (_modalOpen)
          {
            'id': 'reload-confirmation',
            'extent': 'entire viewport',
            'blocksPicking': true,
          },
        if (_busy)
          {
            'id': 'storage-operation',
            'extent': 'entire viewport',
            'blocksPicking': true,
          },
        if (!_ready)
          {
            'id': 'renderer-status',
            'extent': 'entire viewport',
            'blocksPicking': true,
          },
      ],
      'dirty': _dirty,
      'busy': _busy,
      'rendererStatus': _controller.status.value.runtimeType.toString(),
      'previewActive': _previewCamera != null,
      'timelineMicroseconds': _timeline.position.inMicroseconds,
      'presentedFrame': presented == null
          ? null
          : {
              'id': presented.frame.frameId,
              'elapsedMicroseconds': presented.elapsed.inMicroseconds,
              'sceneRevision': null,
              'width': presented.frame.physicalSize.width,
              'height': presented.frame.physicalSize.height,
              'correlation':
                  'presenter accepted frame; submitted scene revision unavailable',
            },
      'pixelVisibility': 'unknown',
      'agentProviderGaps': List<String>.of(_providerGaps),
    };
  }

  Widget _canvas() => LayoutBuilder(
    builder: (context, constraints) {
      _viewportSize = constraints.biggest;
      _dpr = MediaQuery.devicePixelRatioOf(context);
      return MouseRegion(
        key: _canvasKey,
        onExit: (_) {
          _pointer = null;
          _hoveredId = null;
          _uiRevision++;
        },
        child: AbsorbPointer(
          absorbing: _busy || _modalOpen,
          child: _canvasContents(),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _scene.document.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  _busy
                      ? 'Working...'
                      : _previewCamera != null
                      ? 'Camera preview'
                      : _dirty
                      ? 'Unsaved changes'
                      : 'Saved',
                  key: const ValueKey('save-status'),
                ),
                Tooltip(
                  message: widget.saveLocation,
                  child: _button(
                    'Save',
                    Icons.save_outlined,
                    !_busy && _previewCamera == null ? _save : null,
                  ),
                ),
                _button(
                  'Reload',
                  Icons.folder_open,
                  !_busy && _previewCamera == null ? _reload : null,
                ),
                _button(
                  'Undo',
                  Icons.undo,
                  _editing && _scene.tools.canUndo
                      ? () => _edit(_scene.tools.undo)
                      : null,
                ),
                _button(
                  'Redo',
                  Icons.redo,
                  _editing && _scene.tools.canRedo
                      ? () => _edit(_scene.tools.redo)
                      : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final mode in GizmoMode.values)
                  ChoiceChip(
                    label: Text(mode.name),
                    selected: _gizmo.mode == mode,
                    onSelected: _editing
                        ? (_) => _edit(() => _gizmo.mode = mode)
                        : null,
                  ),
                _button(
                  _previewCamera == null ? 'Preview camera' : 'Stop preview',
                  _previewCamera == null ? Icons.play_arrow : Icons.stop,
                  _ready && !_busy ? _preview : null,
                ),
                if (_previewCamera != null)
                  Text(
                    '${(_timeline.position.inMilliseconds / 1000).toStringAsFixed(1)} / 3 s',
                  ),
              ],
            ),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                _notice!,
                style: TextStyle(
                  color: _error ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => constraints.maxWidth >= 780
                  ? Row(
                      children: [
                        Expanded(child: _canvas()),
                        const VerticalDivider(width: 1),
                        SizedBox(
                          width: 300,
                          child: Listener(
                            onPointerDown: (_) {
                              _activePanel = 'inspector';
                              _uiRevision++;
                            },
                            child: _inspector(),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(child: _canvas()),
                        const Divider(height: 1),
                        SizedBox(
                          height: constraints.maxHeight * .43,
                          child: Listener(
                            onPointerDown: (_) {
                              _activePanel = 'inspector';
                              _uiRevision++;
                            },
                            child: _inspector(),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    ),
  );
}
