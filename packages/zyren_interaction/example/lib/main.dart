import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'package:zyren_inspector/zyren_inspector.dart';
import 'agent_host.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const InteractionDemo(),
  ),
);

class InteractionDemo extends StatefulWidget {
  /// Tests can substitute only the viewport while checking the real responsive UI.
  final Widget Function(SceneController controller)? viewportBuilder;
  final SceneRuntime? runtime;
  const InteractionDemo({super.key, this.viewportBuilder, this.runtime});
  @override
  State<InteractionDemo> createState() => InteractionDemoState();
}

class InteractionDemoState extends State<InteractionDemo> {
  final scene = Scene()..background = Color3.hex(0x161c24);
  final tools = SceneToolsPlugin(selectOnTap: false);
  late final SceneController controller;
  late final SceneInteractionRouter interaction;
  final objects = <Mesh>[];
  late final ExampleAgentHost agentHost;
  StreamSubscription<void>? _changes;
  TransformSession? _drag;
  int? _dragPointer;
  Vec3? _start;
  ViewportPoint? _startPointer;
  String hovered = 'None', captured = 'None';
  bool _closing = false;
  bool _inspectorOpen = false;
  ScenePointerEvent? _lastPointer;

  @override
  void initState() {
    super.initState();
    controller = SceneController(
      scene: scene,
      camera: OrthographicCamera(
        position: const Vec3(0, 0, 6),
        verticalSize: 4,
      ),
      runtime:
          widget.runtime ??
          (Platform.isMacOS || Platform.isIOS
              ? const SceneRuntime.nativeMetal()
              : Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : const SceneRuntime()),
      options: EngineOptions(
        presentation:
            widget.runtime == null &&
                (Platform.isMacOS || Platform.isIOS || Platform.isAndroid)
            ? PresentationPolicy.requireNative
            : PresentationPolicy.readbackOnly,
      ),
    );
    interaction = SceneInteractionRouter(
      scene: scene,
      camera: () => controller.camera,
      viewport: () => (controller.input as ViewportInputSource).viewport,
      onError: (error, stack) => FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      ),
    );
    controller.use(tools);
    controller.use(
      SceneInteractionPlugin(
        interaction,
        gestures: {SceneGesture.tap, SceneGesture.pointerDrag},
      ),
    );
    agentHost = ExampleAgentHost(
      controller: controller,
      router: interaction,
      tools: tools,
      uiState: () => {
        'overlays': _inspectorOpen ? ['scene-inspector'] : [],
        'pointerBlockedByUi': _inspectorOpen,
        'pointer': _lastPointer == null
            ? null
            : {
                'x': _lastPointer!.point.x,
                'y': _lastPointer!.point.y,
                'kind': _lastPointer!.kind.name,
                'coordinateSpace': 'viewport-local-logical-top-left',
              },
      },
    );
    controller.use(agentHost.inspector);
    controller.use(agentHost);
    _changes = tools.changes.listen((_) => _refresh());
    _addObjects();
  }

  void _refresh() {
    if (mounted && !_closing) setState(() {});
  }

  void _addObjects() {
    for (final object in objects) {
      scene.remove(object);
    }
    objects.clear();
    for (final (name, x, color) in [
      ('Orange', -.8, 0xe8a05a),
      ('Blue', .8, 0x5ea6d8),
    ]) {
      final object = scene.add(
        Mesh(
          BoxGeometry(width: .8, height: .8, depth: .8),
          UnlitMaterial(color: Color3.hex(color)),
          name: name,
        ),
      )..position = Vec3(x, 0, 0);
      objects.add(object);
      interaction.register(object, (event) => _pointer(object, event));
    }
  }

  void _pointer(Mesh object, ObjectPointerEvent event) {
    switch (event.phase) {
      case ObjectPointerPhase.enter:
        hovered = object.name!;
      case ObjectPointerPhase.leave:
        hovered = 'None';
      case ObjectPointerPhase.down:
        if (_drag != null ||
            (event.source.buttons != 0 && event.source.buttons != 1)) {
          return;
        }
        tools.select(object);
        _drag = tools.beginTransform(object);
        _dragPointer = event.source.pointer;
        _start = object.position;
        _startPointer = event.source.point;
        event.capturePointer();
      case ObjectPointerPhase.gotCapture:
        captured = object.name!;
      case ObjectPointerPhase.move:
        if (_dragPointer != event.source.pointer || _drag == null) return;
        final metrics = (controller.input as ViewportInputSource).viewport;
        if (metrics.isUsable) {
          // The fixed orthographic camera fits its vertical extent to the view.
          final scale = 4 / metrics.height;
          _drag!.update(
            position:
                _start! +
                Vec3(
                  (event.source.point.x - _startPointer!.x) * scale,
                  -(event.source.point.y - _startPointer!.y) * scale,
                  0,
                ),
          );
        }
      case ObjectPointerPhase.up:
        if (_dragPointer == event.source.pointer) {
          _drag?.commit();
          _drag = null;
          _dragPointer = null;
        }
      case ObjectPointerPhase.cancel:
        if (_dragPointer == event.source.pointer) {
          _drag?.cancel();
          _drag = null;
          _dragPointer = null;
        }
      case ObjectPointerPhase.lostCapture:
        captured = 'None';
      default:
        break;
    }
    _refresh();
  }

  void removeSelected() {
    final selected = tools.selected;
    if (selected == null) return;
    selected.parent?.remove(selected);
    objects.remove(selected);
    _refresh();
  }

  Future<void> _inspect() async {
    _inspectorOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: StreamBuilder<void>(
            stream: tools.changes,
            builder: (_, _) => SceneInspector(
              controller: controller,
              selectedObject: tools.selected,
              onSelectionChanged: controller.status.value is SceneReady
                  ? tools.select
                  : null,
            ),
          ),
        ),
      );
    } finally {
      _inspectorOpen = false;
    }
  }

  @override
  void dispose() {
    _closing = true;
    interaction.dispose();
    unawaited(_changes?.cancel());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Object interaction',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text('Hover: $hovered'),
                    Text('Capture: $captured'),
                    Text('Selected: ${tools.selected?.name ?? 'None'}'),
                  ],
                ),
                TextButtonTheme(
                  data: TextButtonThemeData(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: tools.selected == null
                            ? null
                            : removeSelected,
                        child: const Text('Remove'),
                      ),
                      TextButton(
                        onPressed: tools.canUndo && _drag == null
                            ? tools.undo
                            : null,
                        child: const Text('Undo'),
                      ),
                      TextButton(
                        onPressed: () {
                          _addObjects();
                          _refresh();
                        },
                        child: const Text('Reset'),
                      ),
                      TextButton(
                        onPressed: _inspect,
                        child: const Text('Inspector'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              'Drag a box. Release outside the view to finish. Camera is fixed.',
            ),
          ),
          Expanded(
            child: MouseRegion(
              onExit: (_) {
                interaction.clearHover();
                _refresh();
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.viewportBuilder?.call(controller) ??
                      SceneView(
                        controller: controller,
                        onPointer: (event) => _lastPointer = event,
                        loadingBuilder: (_) => const ZeroState(
                          title: 'Starting renderer',
                          message: 'Preparing the native viewport.',
                        ),
                        errorBuilder: (_, issue, retry) => ZeroState(
                          title: 'Viewport failed',
                          message: issue.message,
                          actionLabel: 'Retry',
                          onAction: retry,
                        ),
                      ),
                  if (objects.isEmpty)
                    ZeroState(
                      title: 'No objects',
                      message: 'Reset the scene to try selection and dragging.',
                      actionLabel: 'Reset scene',
                      onAction: () {
                        _addObjects();
                        _refresh();
                      },
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
