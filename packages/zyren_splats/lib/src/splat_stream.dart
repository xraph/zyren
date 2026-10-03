import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_pointclouds/streaming.dart';
import 'package:zyren_pointclouds/zyren_pointclouds.dart';
import 'gaussian.dart';
import 'scene_plugin.dart';

/// Offline source-preserving Gaussian hierarchy with three-sigma bounds.
final class GaussianOctree {
  final SpatialChunk root;
  final Map<String, GaussianCloudData> chunks;
  GaussianOctree._(this.root, this.chunks);
  factory GaussianOctree.fromData(
    GaussianCloudData data, {
    int samplesPerChunk = 512,
    int maxDepth = 16,
  }) {
    final points = PointCloudData(
      sourceUri: data.sourceUri,
      sourceVersion: data.sourceVersion,
      points: data.splats.map((s) => s.mean),
    );
    final pointTree = PointCloudOctree.fromData(
      points,
      samplesPerChunk: samplesPerChunk,
      maxDepth: maxDepth,
    );
    final chunks = <String, GaussianCloudData>{};
    SpatialChunk convert(SpatialChunk n) {
      final source = pointTree.chunks[n.id]!;
      final selected = data.select(
        List.generate(source.count, (i) => source.identityAt(i).$3),
      );
      chunks[n.id] = selected;
      final children = n.children.map(convert).toList();
      var bounds = const Bounds3.empty();
      for (final s in selected.splats) {
        final extent = Vec3(
          3 * math.sqrt(s.covariance.xx),
          3 * math.sqrt(s.covariance.yy),
          3 * math.sqrt(s.covariance.zz),
        );
        bounds = bounds.union(Bounds3(s.mean - extent, s.mean + extent));
      }
      for (final child in children) {
        bounds = bounds.union(child.bounds);
      }
      return SpatialChunk(
        id: n.id,
        uri: n.uri,
        version: n.version,
        bounds: bounds,
        geometricError: children.isEmpty ? 0 : bounds.size.length,
        decodedBytes: selected.splats.length * 104,
        gpuBytes: selected.splats.length * 184,
        children: children,
      );
    }

    final root = convert(pointTree.root);
    return GaussianOctree._(root, Map.unmodifiable(chunks));
  }
  Future<SpatialPayload<GaussianCloudData>> load(
    SpatialChunk chunk,
    LoadCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final data = chunks[chunk.id];
    if (data == null ||
        data.sourceUri != chunk.uri ||
        data.sourceVersion != chunk.version) {
      throw StateError('Gaussian chunk source version mismatch.');
    }
    return SpatialPayload(
      data,
      decodedBytes: data.splats.length * 104,
      gpuBytes: data.splats.length * 184,
    );
  }
}

/// The visible chunks share one draw and one global mean-depth order. Drawing
/// each tile separately would produce incorrect overlap order at tile borders.
final class GaussianStreamPlugin extends ScenePlugin {
  final SpatialStreamer<GaussianCloudData> stream;
  final Group object;
  final String instanceId;
  final SplatLimits limits;
  final bool closeStreamOnDetach;
  Registration? _changed;
  AttachmentScope _lifetime = AttachmentScope();
  Registration onClose(void Function() callback) => _lifetime.onClose(callback);
  GaussianSplatPlugin? _renderer;
  int _revision = -1;
  GaussianStreamPlugin({
    required this.stream,
    this.instanceId = 'default',
    Group? object,
    this.limits = const SplatLimits(),
    this.closeStreamOnDetach = true,
  }) : object = object ?? Group(name: 'streamed Gaussians');
  @override
  String get id => 'zyren.splats.stream.$instanceId';
  GaussianSplatPlugin? get renderer => _renderer;
  bool get hasPendingUpdate => _revision != stream.revision;
  @override
  void attach(PluginContext context) {
    if (stream.isClosed) {
      throw StateError('Cannot attach a closed Gaussian stream.');
    }
    if (_lifetime.isClosed) _lifetime = AttachmentScope();
    context.scene.add(object);
    _changed = stream.onChanged(context.invalidate);
  }

  GaussianCloudData? get visibleData {
    final chunks = stream.visible.values.toList();
    if (chunks.isEmpty) return null;
    final records = <GaussianSplat>[],
        identities = <(Uri, String, int)>[],
        seen = <(Uri, String, int)>{};
    for (final chunk in chunks) {
      for (var i = 0; i < chunk.splats.length; i++) {
        final identity = chunk.identityAt(i);
        if (!seen.add(identity)) {
          throw StateError('Visible Gaussian chunks overlap source records.');
        }
        limits.checkCount(records.length + 1);
        records.add(chunk.splats[i]);
        identities.add(identity);
      }
    }
    return GaussianCloudData(
      sourceUri: chunks.first.sourceUri,
      sourceVersion: chunks.first.sourceVersion,
      splats: records,
      sourceIdentities: identities,
      limits: limits,
    );
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    stream.update(
      context.camera,
      PhysicalSize(frame.width, frame.height),
      transform: object.worldMatrix,
    );
    if (_revision != stream.revision) {
      final data = visibleData;
      if (data != null) {
        if (_renderer == null) {
          final capacity = math.min(
            limits.maxSplats,
            math.min(
              limits.maxUploadBytes ~/ 64,
              stream.budget.maxGpuBytes ~/ 184,
            ),
          );
          final renderer = GaussianSplatPlugin(
            data: data,
            object: object,
            instanceId: instanceId,
            limits: limits,
            capacity: capacity,
          );
          _renderer = renderer;
          await renderer.attach(context);
        } else {
          _renderer!.data = data;
        }
      }
      _renderer?.enabled = data != null;
      _revision = stream.revision;
    }
    await _renderer?.beforeRender(context, frame);
  }

  @override
  Future<void> detach(PluginContext context) async {
    _lifetime.close();
    await _lifetime.whenClosed;
    _changed?.dispose();
    _changed = null;
    await _renderer?.detach(context);
    _renderer = null;
    _revision = -1;
    object.parent?.remove(object);
    if (closeStreamOnDetach) await stream.close();
  }
}
