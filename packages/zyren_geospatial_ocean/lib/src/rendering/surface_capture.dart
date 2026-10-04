import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'material.dart';

/// One actual water draw. Geometry, rigid world transform and morph weights are
/// mirrored into the boundary capture. Skinning and non-unit scale are excluded.
final class OceanBoundaryDraw {
  final OceanWaterMaterial water;
  final Mesh mesh;

  /// Keeps the volume boundary when its surface visualization is hidden.
  final bool includeHidden;
  OceanBoundaryDraw({
    required this.water,
    required this.mesh,
    this.includeHidden = false,
  }) {
    if (!identical(mesh.material, water.material) || mesh is SkinnedMesh) {
      throw ArgumentError(
        'A boundary draw needs its water material and an unskinned mesh.',
      );
    }
  }
}

/// GPU-only surface distance and facing capture. A dedicated native view keeps
/// its attachments separate from the scene's history and opaque input capture.
/// R/G encode camera-forward distance as R*32+G metres; B is 1 entering water,
/// 2 leaving water; A=0 means no captured surface. No readback runs per frame.
final class OceanSurfaceCapture {
  final GpuScope _scope;
  final SceneCaptureView _view;
  final Scene _scene;
  final GpuResource<Buffer> _forward;
  final List<_BoundaryMesh> _meshes;
  final GpuResource<Texture> texture;
  final PhysicalSize size;
  int get logicalBytes => size.width * size.height * 8 + 16;
  bool get isClosed => _scope.isClosed;
  bool _busy = false;
  Camera? _camera;
  Mat4? _projection;
  Vec3? _position, _target, _up;
  OceanSurfaceCapture._(
    this._scope,
    this._view,
    this._scene,
    this._forward,
    this._meshes,
    this.texture,
    this.size,
  );

  static Future<OceanSurfaceCapture> create(
    GpuScope parent,
    CaptureBackend backend, {
    required Iterable<OceanBoundaryDraw> draws,
    required PhysicalSize size,
    int maxPixels = 2073600,
  }) => createWithViewFactory(
    parent,
    createView: backend.createCaptureView,
    draws: draws,
    size: size,
    maxPixels: maxPixels,
  );

  /// Uses a same-device capture factory, including PluginContext.createCaptureView.
  static Future<OceanSurfaceCapture> createWithViewFactory(
    GpuScope parent, {
    required Future<SceneCaptureView> Function() createView,
    required Iterable<OceanBoundaryDraw> draws,
    required PhysicalSize size,
    int maxPixels = 2073600,
  }) async {
    final entries = List<OceanBoundaryDraw>.of(draws);
    if (entries.isEmpty ||
        entries.length > 4096 ||
        size.width < 1 ||
        size.height < 1 ||
        size.width * size.height > maxPixels ||
        maxPixels < 1 ||
        maxPixels > 16777216) {
      throw ArgumentError('Surface capture exceeds its draw or pixel budget.');
    }
    final scope = parent.createChild(label: 'ocean-surface-capture');
    SceneCaptureView? view;
    try {
      view = await createView();
      final target = await scope.resources.createTexture(
        TextureDescriptor(
          width: size.width,
          height: size.height,
          format: TextureFormat.rgba16Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.renderAttachment,
            TextureUsage.copySource,
          },
        ),
      );
      final forward = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 16,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(backgroundAlpha: 0, hdr: true);
      final meshes = <_BoundaryMesh>[];
      for (final entry in entries) {
        final material = await entry.water.createBoundaryMaterial(
          scope,
          forward,
        );
        final mesh = _BoundaryMesh(entry, material);
        meshes.add(mesh);
        scene.add(mesh);
      }
      return OceanSurfaceCapture._(
        scope,
        view,
        scene,
        forward,
        meshes,
        target,
        size,
      );
    } catch (_) {
      await view?.close();
      await scope.close();
      rethrow;
    }
  }

  /// Call before the corresponding scene submission. Rejected or stale captures
  /// are not valid inputs to underwater composition. A new camera, pose, geometry
  /// or wave snapshot requires a new capture.
  Future<SceneCaptureReceipt> update(Camera camera) async {
    if (isClosed || _busy) {
      throw StateError('Surface capture is closed or busy.');
    }
    if (camera is! PerspectiveCamera && camera is! OrthographicCamera) {
      throw UnsupportedError(
        'Surface capture supports perspective and orthographic cameras.',
      );
    }
    _busy = true;
    _camera = null;
    try {
      final forward = (camera.target - camera.position).normalized();
      final projection = camera.projectionMatrix(size.width / size.height);
      final position = camera.position, target = camera.target, up = camera.up;
      final matrix = projection.storage.toList();
      // Preserve XY exactly, while capturing surfaces hidden by the main near
      // plane. This matters when the camera straddles a crest.
      final z =
          (camera is PerspectiveCamera
                  ? PerspectiveCamera(
                      near: .0001,
                      far: 60000,
                      depthStrategy: camera.depthStrategy,
                    )
                  : OrthographicCamera(
                      near: 0,
                      far: 60000,
                      depthStrategy: camera.depthStrategy,
                    ))
              .projectionMatrix(1)
              .storage;
      matrix[10] = z[10];
      matrix[14] = z[14];
      final captureCamera = _CaptureCamera(camera, Mat4(matrix));
      for (final mesh in _meshes) {
        mesh.synchronize();
      }
      await _scope.resources.writeBuffer(
        _forward,
        Float32List.fromList([forward.x, forward.y, forward.z, 0]),
      );
      final receipt = await _view.capture(
        FrameSubmission.capture(
          scene: _scene,
          camera: captureCamera,
          size: size,
        ),
        texture,
      );
      if (!receipt.admission.candidateReady) {
        throw StateError(
          'Water boundary capture did not admit its complete surface.',
        );
      }
      if (_meshes.any((mesh) => !mesh.isCurrent) ||
          position != camera.position ||
          target != camera.target ||
          up != camera.up ||
          projection != camera.projectionMatrix(size.width / size.height)) {
        throw StateError('Camera changed during water boundary capture.');
      }
      _camera = camera;
      _position = position;
      _target = target;
      _up = up;
      _projection = projection;
      return receipt;
    } finally {
      _busy = false;
    }
  }

  void checkCurrent(Camera camera, PhysicalSize viewport) {
    if (isClosed ||
        _busy ||
        !identical(_camera, camera) ||
        camera.position != _position ||
        camera.target != _target ||
        camera.up != _up ||
        (viewport.width / viewport.height - size.width / size.height).abs() >
            1e-10 ||
        camera.projectionMatrix(size.width / size.height) != _projection ||
        _meshes.any((mesh) => !mesh.isCurrent)) {
      throw StateError(
        'Underwater composition requires a current surface capture for this camera and aspect.',
      );
    }
  }

  Future<void> close() async {
    await _view.close();
    await _scope.close();
  }
}

final class _BoundaryMesh extends Mesh {
  final OceanBoundaryDraw draw;
  late Mat4 _matrix;
  late List<double> _weights;
  late int _geometryRevision, _surfaceRevision;
  _BoundaryMesh(this.draw, ShaderMaterial material)
    : super(draw.mesh.geometry, material) {
    synchronize();
  }
  @override
  Mat4 get localMatrix => _matrix;
  bool get _sourceVisible {
    if (draw.includeHidden) return true;
    for (Object3D? node = draw.mesh; node != null; node = node.parent) {
      if (!node.visible) return false;
    }
    return true;
  }

  bool get isCurrent =>
      draw.water.isReady &&
      draw.water.surfaceRevision == _surfaceRevision &&
      identical(draw.mesh.material, draw.water.material) &&
      identical(geometry, draw.mesh.geometry) &&
      geometry.revision == _geometryRevision &&
      _matrix == draw.mesh.worldMatrix &&
      visible == _sourceVisible &&
      _weights.length == draw.mesh.morphWeights.length &&
      Iterable<int>.generate(
        _weights.length,
      ).every((i) => _weights[i] == draw.mesh.morphWeights[i]);
  void synchronize() {
    if (!draw.water.isReady ||
        !identical(draw.mesh.material, draw.water.material)) {
      throw StateError('The captured water material was replaced or closed.');
    }
    final matrix = draw.mesh.worldMatrix;
    final m = matrix.storage;
    final axes = [
      for (var i = 0; i < 3; i++) Vec3(m[i * 4], m[i * 4 + 1], m[i * 4 + 2]),
    ];
    if (axes.any((v) => (v.length - 1).abs() > 1e-8) ||
        axes[0].cross(axes[1]).distanceTo(axes[2]) > 1e-8) {
      throw ArgumentError(
        'Water capture requires a proper rigid transform in metres.',
      );
    }
    if (!identical(geometry, draw.mesh.geometry)) {
      throw StateError('Replace the capture after changing water geometry.');
    }
    _matrix = matrix;
    _geometryRevision = geometry.revision;
    _surfaceRevision = draw.water.surfaceRevision;
    _weights = List.of(draw.mesh.morphWeights);
    morphWeights = _weights;
    visible = _sourceVisible;
  }
}

final class _CaptureCamera extends Camera {
  final Mat4 _projection;
  @override
  Vec3 target;
  @override
  Vec3 up;
  _CaptureCamera(Camera source, this._projection)
    : target = source.target,
      up = source.up,
      super(depthStrategy: source.depthStrategy) {
    position = source.position;
  }
  @override
  Mat4 projectionMatrix(double aspect) => _projection;
}
