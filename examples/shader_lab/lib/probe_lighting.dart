import 'package:zyren/zyren.dart';

/// The lab queues one probe job before each main frame. Captures have their own
/// view and never call SceneEngine recursively or replay main-view effect graphs.
final class ProbeLabLighting extends ScenePlugin {
  final EnvironmentLighting global;
  ProbeLabLighting(this.global);
  @override
  String get id => 'shader-lab.probes';
  ReflectionProbes? probes;
  PluginContext? _context;
  bool supported = false, enabled = true;
  int faceSize = 32, revision = 0;
  int? _request;
  bool _cancel = false;
  String? error;
  void update(int id) {
    _request = id;
    error = null;
    _context?.invalidate();
  }

  void cancel() {
    _cancel = true;
    _request = null;
    _context?.invalidate();
  }

  void setEnabled(bool value) {
    enabled = value;
    _context?.scene.reflectionProbes = value ? probes : null;
    _context?.invalidate();
  }

  @override
  Future<void> attach(PluginContext context) async {
    _context = context;
    supported = context.capabilities.supports(RenderFeature.sceneCapture);
    if (!supported) return;
    probes = await context.createReflectionProbes();
    context.scene.reflectionProbes = probes;
    context.scope.onClose(() {
      if (identical(context.scene.reflectionProbes, probes)) {
        context.scene.reflectionProbes = null;
      }
      _context = null;
      probes = null;
    });
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    final collection = probes;
    if (collection == null) return;
    try {
      if (_cancel) {
        _cancel = false;
        await collection.cancel();
      }
      final id = _request;
      if (id != null) {
        _request = null;
        final x = id == 0 ? -1.5 : 1.5;
        await collection.update(
          ReflectionProbeDescriptor(
            id: id,
            position: Vec3(x, 0, 2),
            bounds: Bounds3(
              Vec3(id == 0 ? -5 : 0, -4, -2),
              Vec3(id == 0 ? 0 : 5, 4, 4),
            ),
            faceSize: faceSize,
          ),
          scene: context.scene,
          contentRevision: ++revision,
          environment: global.map == null
              ? null
              : Environment(
                  map: global.map!,
                  intensity: global.intensity,
                  rotation: global.rotation,
                ),
        );
      }
      if (collection.pending) await collection.advance();
    } catch (e) {
      error = e.toString();
      await collection.cancel();
    }
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    if (probes?.pending ?? false) context.invalidate();
  }
}
