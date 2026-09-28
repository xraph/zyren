import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'worker.dart';
import 'surface.dart';
import 'worker_session.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

part 'backend.dart';
part 'resources.dart';
part 'shaders.dart';
part 'graphs.dart';
part 'gpu_context.dart';

/// One native GPU device, owned by a persistent worker isolate.
/// Await [dispose] when you no longer need it.
class NativeRenderer implements SceneRenderer {
  RendererCapabilities get _capabilities => RendererCapabilities(
    backend: _deviceInfo.backend,
    adapterName: _deviceInfo.adapterName,
    sampleCounts: _deviceInfo.sampleCounts,
    name: 'wgpu-native',
    features: {
      RenderFeatures.indexedMeshes,
      RenderFeatures.diffuseLighting,
      RenderFeatures.unlitMaterials,
      RenderFeatures.rgbaReadback,
      RenderFeatures.colorTextures,
      RenderFeatures.alphaMaterials,
      RenderFeatures.portablePrimitives,
      RenderFeatures.materialSidedness,
      RenderFeature.hdr,
      RenderFeature.standardMaterials,
      RenderFeature.punctualLights,
      RenderFeature.shadowMaps,
      RenderFeature.instancing,
      RenderFeature.spatialAntialiasing,
      RenderFeature.bloom,
      RenderFeature.sectionClipping,
      if (_deviceInfo.sampleCounts.contains(4))
        RenderFeature.multisampleAntialiasing,
    },
    maxDimension: 4096,
  );
  @override
  RendererCapabilities get capabilities => _capabilities;

  static final _finalizer = Finalizer<WorkerSession>(
    (worker) => worker.abort(),
  );
  final WorkerSession _worker;
  late final NativeDeviceInfo _deviceInfo;
  final _sceneEncoder = ScenePacketEncoder(viewId: 1);
  int _nextView = 1, _owners = 1;
  Future<Object?>? _frame;
  Future<void>? _disposal;
  bool _closed = false;

  NativeRenderer._(this._worker) {
    _finalizer.attach(this, _worker, detach: this);
  }

  static Future<NativeRenderer> create() async {
    final value = NativeRenderer._(await WorkerSession.start(renderWorker));
    try {
      value._deviceInfo = await _NativeResourceDevice(
        _workerTransport(value._worker),
      ).deviceInfo();
      return value;
    } catch (_) {
      await value.dispose();
      rethrow;
    }
  }

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
      final future = _renderBinary(
        FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(width, height),
        ),
        _sceneEncoder,
      );
      _frame = future;
      return future.whenComplete(() {
        _frame = null;
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  Future<RenderedFrame> _renderBinary(
    FrameSubmission submission,
    ScenePacketEncoder encoder,
  ) async {
    if (_closed) throw StateError('Renderer has been disposed.');
    final packet = encoder.encode(submission);
    final reply =
        await _worker.request('render', [
              TransferableTypedData.fromList([packet.bytes]),
              submission.size.width,
              submission.size.height,
            ])
            as List<Object>;
    encoder.accept(packet);
    final bytes = (reply[0] as TransferableTypedData)
        .materialize()
        .asUint8List();
    return RenderedFrame(
      bytes,
      submission.size.width,
      submission.size.height,
      uploadedBytes: reply[1] as int,
      residentBytes: reply[2] as int,
    );
  }

  Future<void> _releaseView(int id) async {
    try {
      await _worker.request('sceneClose', [id]);
    } finally {
      if (--_owners == 0) await dispose();
    }
  }

  Future<List<int>> _renderSurfacePacket(
    EncodedScenePacket packet,
    ScenePacketEncoder encoder,
    SurfaceTarget target,
    int frameId,
  ) {
    if (_closed) return Future.error(StateError('Renderer has been disposed.'));
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    final future = _worker
        .request('surfaceRender', [
          TransferableTypedData.fromList([packet.bytes]),
          (target.surface as NativeSurfaceKey).toMessage(),
          target.epoch,
          frameId,
        ])
        .then((value) {
          final receipt = value as List<int>;
          if (receipt.first == 0 || receipt.first == 14) {
            encoder.accept(packet);
          }
          if (receipt.first != 0) {
            throw NativeSurfaceException(
              receipt.first,
              'Surface submission was not published.',
            );
          }
          return receipt.sublist(1);
        });
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
