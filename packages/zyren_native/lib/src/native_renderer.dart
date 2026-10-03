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
part 'gpu_services.dart';
part 'gpu_context.dart';

/// One native GPU device, owned by a persistent worker isolate.
/// Await [dispose] when you no longer need it.
final class _SensorFrame extends RenderedFrame {
  final DepthData? depth;
  const _SensorFrame(
    super.pixels,
    super.width,
    super.height, {
    this.depth,
    super.profile,
    super.uploadedBytes,
    super.residentBytes,
    super.alphaMode,
  });
}

DepthData _metricDepth(Uint8List bytes, FrameSubmission frame) {
  final count = frame.size.width * frame.size.height;
  if (bytes.length != count * 4) {
    throw StateError('Native depth size mismatch.');
  }
  final raw = ByteData.sublistView(bytes),
      values = Float32List(count),
      mask = Uint8List(count);
  final inverse = Mat4(frame.camera.projection).inverted().storage;
  final clear = frame.camera.depthStrategy == DepthStrategy.reversed
      ? 0.0
      : 1.0;
  for (var i = 0; i < count; i++) {
    final z = raw.getFloat32(i * 4, Endian.little);
    if (!z.isFinite || z < 0 || z > 1 || z == clear) continue;
    final x = ((i % frame.size.width + .5) / frame.size.width) * 2 - 1;
    final y = 1 - ((i ~/ frame.size.width + .5) / frame.size.height) * 2;
    final vz = inverse[2] * x + inverse[6] * y + inverse[10] * z + inverse[14];
    final w = inverse[3] * x + inverse[7] * y + inverse[11] * z + inverse[15];
    final metres = -vz / w;
    if (!metres.isFinite || metres <= 0 || metres > 3.4e38) continue;
    values[i] = metres;
    mask[i] = 1;
  }
  return DepthData(size: frame.size, metres: values, validity: mask);
}

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
      RenderFeature.reversedDepth,
      RenderFeature.sectionClipping,
      RenderFeature.selectionOutlines,
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
        _workerGpuSender(value._worker),
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

  Future<_SensorFrame> _renderBinary(
    FrameSubmission submission,
    ScenePacketEncoder encoder, {
    _NativeResourceDevice? resources,
  }) async {
    if (_closed) throw StateError('Renderer has been disposed.');
    if (resources == null &&
        (submission.graph != null || submission.scene.meshShaders.isNotEmpty)) {
      throw UnsupportedError(
        'Custom scene shaders require a native GPU backend.',
      );
    }
    final packet = encoder.encode(submission);
    submission = packet.submission;
    Future<List<Object>> submit(Uint8List bytes) async =>
        await _worker.request(
              submission.target is ReadbackTarget &&
                      (submission.target as ReadbackTarget).depth
                  ? 'renderSensor'
                  : 'render',
              [
                TransferableTypedData.fromList([bytes]),
                submission.size.width,
                submission.size.height,
              ],
            )
            as List<Object>;
    late List<Object> reply;
    try {
      reply = resources == null
          ? await submit(packet.bytes)
          : await resources.submitFrame(
              packet.submission,
              packet.bytes,
              submit,
              scenePacket: packet,
            );
    } catch (_) {
      encoder.reject(packet);
      rethrow;
    }
    encoder.accept(packet);
    final bytes = (reply[0] as TransferableTypedData)
        .materialize()
        .asUint8List();
    return _SensorFrame(
      bytes,
      submission.size.width,
      submission.size.height,
      depth: reply.length > 4
          ? _metricDepth(
              (reply[4] as TransferableTypedData).materialize().asUint8List(),
              submission,
            )
          : null,
      profile: NativeFrameProfile.fromJson(
        (reply[3] as Map).cast<String, Object?>(),
      ),
      uploadedBytes: reply[1] as int,
      residentBytes: reply[2] as int,
      alphaMode: submission.scene.usesScreenEffects
          ? AlphaMode.premultiplied
          : AlphaMode.straight,
    );
  }

  Future<void> _releaseView(int id) async {
    try {
      await _worker.request('sceneClose', [id]);
    } finally {
      if (--_owners == 0) await dispose();
    }
  }

  Future<List<Object>> _renderSurfacePacket(
    EncodedScenePacket packet,
    ScenePacketEncoder encoder,
    SurfaceTarget target,
    int frameId, {
    Uint8List? bytes,
  }) {
    if (_closed) return Future.error(StateError('Renderer has been disposed.'));
    if (_frame != null) {
      return Future.error(StateError('Only one frame may be in flight.'));
    }
    final future = _worker
        .request('surfaceRender', [
          TransferableTypedData.fromList([bytes ?? packet.bytes]),
          (target.surface as NativeSurfaceKey).toMessage(),
          target.epoch,
          frameId,
        ])
        .then((value) {
          final receipt = (value as List).cast<Object>();
          if (receipt.first == 0 || receipt.first == 14) {
            encoder.accept(packet);
          }
          if (receipt.first != 0) {
            throw NativeSurfaceException(
              receipt.first as int,
              'Surface submission was not published.',
            );
          }
          return receipt.sublist(1);
        })
        .catchError((Object error, StackTrace stack) {
          encoder.reject(packet);
          Error.throwWithStackTrace(error, stack);
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
