import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'worker.dart';
import 'worker_session.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';

part 'backend.dart';

/// One native GPU device, owned by a persistent worker isolate.
/// Await [dispose] when you no longer need it.
class NativeRenderer implements SceneRenderer {
  static final _capabilities = RendererCapabilities(
    name: 'wgpu-native',
    features: {
      RenderFeatures.indexedMeshes,
      RenderFeatures.diffuseLighting,
      RenderFeatures.unlitMaterials,
      RenderFeatures.rgbaReadback,
    },
    maxDimension: 4096,
  );
  @override
  RendererCapabilities get capabilities => _capabilities;

  static final _finalizer = Finalizer<WorkerSession>(
    (worker) => worker.abort(),
  );
  final WorkerSession _worker;
  Set<int> _uploaded = {};
  Future<RenderedFrame>? _frame;
  Future<void>? _disposal;
  bool _closed = false;

  NativeRenderer._(this._worker) {
    _finalizer.attach(this, _worker, detach: this);
  }

  static Future<NativeRenderer> create() async =>
      NativeRenderer._(await WorkerSession.start(renderWorker));

  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) {
    if (_closed) return Future.error(StateError('Renderer has been disposed.'));
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
      return Future.error(
        ArgumentError('Render dimensions must be in [1, 4096].'),
      );
    }
    try {
      return _renderPacket(
        scene.snapshot(camera, width / height, uploaded: _uploaded),
        width,
        height,
      );
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<RenderedFrame> _renderPacket(
    Map<String, Object> frame,
    int width,
    int height,
  ) {
    if (_closed) return Future.error(StateError('Renderer has been disposed.'));
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
      return Future.error(
        ArgumentError('Render dimensions must be in [1, 4096].'),
      );
    }
    Future<RenderedFrame> submit() async {
      final active = (frame['meshes'] as List)
          .map((m) => (m as Map)['geometry'] as int)
          .toSet();
      final bytes =
          await _worker.request('render', [jsonEncode(frame), width, height])
              as TransferableTypedData;
      _uploaded = active;
      return RenderedFrame(bytes.materialize().asUint8List(), width, height);
    }

    final future = submit();
    _frame = future;
    return future.whenComplete(() {
      _frame = null;
    });
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _closed = true;
    try {
      try {
        await _frame;
      } catch (_) {
        /* Cleanup still owns the device. */
      }
      await _worker.close();
    } finally {
      _finalizer.detach(this);
      _worker.abort();
    }
  }
}
