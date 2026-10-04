import 'package:zyren/zyren.dart';
import '../geospatial_plugin.dart';
import '../globe_controls.dart';
import '../point_of_view.dart';
import 'camera_controller.dart';
import 'context.dart';
import 'extension.dart';

/// Globe navigation with independently owned pose and active input registration.
final class GlobeCameraExtension extends GeospatialExtension {
  @override
  final String localId;
  final Mat4? ellipsoidFrame;
  final void Function(GlobeControls)? configure;
  late final GeoGlobeCameraRig camera = GeoGlobeCameraRig(
    instanceId: '$id.controls',
    extensionId: id,
    rigId: localId,
    ellipsoidFrame: ellipsoidFrame,
    configure: configure,
  );
  GlobeCameraExtension({
    required String id,
    this.ellipsoidFrame,
    this.configure,
  }) : localId = id;
  @override
  List<ScenePlugin> get adapters => [camera];
  @override
  Set<String> get incompatiblePluginIds => const {
    'geospatial.globe-controls',
    'geospatial.orbit',
    'zyren.environment-controls',
    'zyren.orbit-controls',
  };
  @override
  void attachGeospatial(GeospatialContext context) {}
}

final class GeoGlobeCameraRig extends ScenePlugin implements GeoCameraRig {
  final String instanceId, extensionId, rigId;
  final Mat4? ellipsoidFrame;
  final void Function(GlobeControls)? configure;
  GlobeControls? _controls;
  PluginContext? _context;
  Registration? _input;
  bool _active = false;
  GeoGlobeCameraRig({
    required this.instanceId,
    required this.extensionId,
    required this.rigId,
    this.ellipsoidFrame,
    this.configure,
  });
  GlobeControls? get controls => _controls;
  @override
  String get id => instanceId;
  @override
  Set<String> get dependencies => {GeospatialPlugin.pluginId, extensionId};
  @override
  GeospatialCameraPose get pose =>
      GeospatialCameraPose.fromCamera(_controls!.camera);
  @override
  void attach(PluginContext context) {
    if (context.camera is! PerspectiveCamera) {
      throw UnsupportedError(
        'Managed globe rigs require a perspective camera.',
      );
    }
    final input = context.input;
    if (input != null && input is! ViewportInputSource) {
      throw ArgumentError(
        'Globe navigation needs logical viewport dimensions.',
      );
    }
    _context = context;
    final privateCamera = PerspectiveCamera();
    GeospatialCameraPose.fromCamera(context.camera).applyTo(privateCamera);
    final control = _controls = GlobeControls(
      privateCamera,
      scene: context.scene,
      ellipsoid: context.service(geospatialReference).ellipsoid,
      ellipsoidFrame: ellipsoidFrame,
      requestFrame: context.invalidate,
      viewport: input is ViewportInputSource
          ? input.viewport
          : const ViewportMetrics(1, 1),
    );
    context.scope.onClose(() {
      _input?.dispose();
      _input = null;
      control.dispose();
      if (identical(_controls, control)) _controls = null;
    });
    configure?.call(control);
    control.enabled = false;
    if (input != null) {
      context.scope.keep(input.registerGesture(SceneGesture.pointerDrag));
      context.scope.keep(input.registerGesture(SceneGesture.scroll));
    }
    context.scope.keep(
      context.service(geospatialRuntime).cameras.registerRig(rigId, this),
    );
  }

  @override
  void setActive(bool active) {
    _active = active;
    final context = _context, controls = _controls;
    _input?.dispose();
    _input = null;
    if (controls == null || context == null) return;
    controls.enabled = active;
    final input = context.input;
    if (active && input != null && !context.scope.isClosed) {
      _input = InputRouter.forSource(input).register(
        id: id,
        priority: InputPriority.navigation,
        navigation: true,
        claims: (_) => _active,
        onEvent: (event) {
          if (input is ViewportInputSource) controls.viewport = input.viewport;
          controls.handlePointer(event);
        },
      );
    }
    if (!context.scope.isClosed) context.invalidate();
  }

  @override
  GeospatialCameraPose constrain(GeospatialCameraPose value) {
    final base = pose;
    try {
      value.applyTo(_controls!.camera);
      _controls!.adjustCamera();
      return pose;
    } finally {
      base.applyTo(_controls!.camera);
    }
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (!_active) return;
    final input = context.input;
    if (input is ViewportInputSource) _controls!.viewport = input.viewport;
    _controls!.update(
      frame.delta.inMicroseconds / Duration.microsecondsPerSecond,
    );
    context.service(geospatialRuntime).cameras.publish(rigId, context.camera);
  }

  @override
  void detach(PluginContext context) {
    setActive(false);
    _controls = null;
    _context = null;
  }
}
