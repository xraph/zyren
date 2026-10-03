import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'cloud.dart';
import 'scene_cloud.dart';
import 'spatial_stream.dart';

/// Source-domain filters. Missing intensity cannot satisfy an intensity range.
final class PointCloudFilter {
  final Set<int>? classifications;
  final double? minIntensity, maxIntensity;
  final bool includeWithheld;
  PointCloudFilter({
    Set<int>? classifications,
    this.minIntensity,
    this.maxIntensity,
    this.includeWithheld = true,
  }) : classifications = classifications == null
           ? null
           : Set.unmodifiable(classifications) {
    if (this.classifications?.any((v) => v < 0 || v > 255) ?? false) {
      throw ArgumentError('Classification must be a byte.');
    }
    if (minIntensity != null && !minIntensity!.isFinite ||
        maxIntensity != null && !maxIntensity!.isFinite ||
        minIntensity != null &&
            maxIntensity != null &&
            minIntensity! > maxIntensity!) {
      throw ArgumentError('Invalid intensity range.');
    }
  }
  bool accepts(PointCloudData data, int index) {
    if (classifications != null &&
        !classifications!.contains(data.classificationAt(index))) {
      return false;
    }
    final attrs = data.attributesAt(index);
    if (!includeWithheld && attrs['withheld'] == true) return false;
    if (minIntensity != null || maxIntensity != null) {
      final value = attrs['intensity'];
      if (value is! num ||
          minIntensity != null && value < minIntensity! ||
          maxIntensity != null && value > maxIntensity!) {
        return false;
      }
    }
    return true;
  }
}

/// Offline hierarchy builder for already-decoded sources. Every LOD keeps real
/// source samples. Persistent/network hierarchies use SpatialChunk and a loader.
final class PointCloudOctree {
  final SpatialChunk root;
  final Map<String, PointCloudData> chunks;
  PointCloudOctree._(this.root, this.chunks);
  factory PointCloudOctree.fromData(
    PointCloudData data, {
    int samplesPerChunk = 1024,
    int maxDepth = 16,
    int maxStoredSamples = 1000000,
  }) {
    RangeError.checkValueInInterval(samplesPerChunk, 1, 250000);
    RangeError.checkValueInInterval(maxDepth, 1, 24);
    final chunks = <String, PointCloudData>{};
    var stored = 0;
    SpatialChunk build(List<int> indices, String id, int depth) {
      var bounds = const Bounds3.empty();
      for (final i in indices) {
        final p = data.pointAt(i);
        bounds = bounds.union(Bounds3(p, p));
      }
      final leaves =
          indices.length <= samplesPerChunk ||
          depth == maxDepth ||
          bounds.size.length < 1e-12;
      final children = <SpatialChunk>[];
      if (!leaves) {
        final center = bounds.center;
        final groups = List.generate(8, (_) => <int>[]);
        for (final i in indices) {
          final p = data.pointAt(i);
          groups[(p.x >= center.x ? 1 : 0) |
                  (p.y >= center.y ? 2 : 0) |
                  (p.z >= center.z ? 4 : 0)]
              .add(i);
        }
        for (var i = 0; i < 8; i++) {
          if (groups[i].isNotEmpty) {
            children.add(build(groups[i], '$id/$i', depth + 1));
          }
        }
      }
      final selected = leaves
          ? indices
          : List.generate(
              math.min(indices.length, samplesPerChunk),
              (i) =>
                  indices[i *
                      indices.length ~/
                      math.min(indices.length, samplesPerChunk)],
            );
      stored += selected.length;
      if (stored > maxStoredSamples) {
        throw StateError(
          'Offline hierarchy exceeds its retained-sample budget.',
        );
      }
      final subset = data.select(selected);
      chunks[id] = subset;
      return SpatialChunk(
        id: id,
        uri: data.sourceUri,
        version: data.sourceVersion,
        bounds: bounds,
        geometricError: leaves ? 0 : bounds.size.length,
        decodedBytes: subset.payloadBytes,
        gpuBytes: subset.count * 12,
        children: children,
      );
    }

    final root = build(List.generate(data.count, (i) => i), 'root', 0);
    return PointCloudOctree._(root, Map.unmodifiable(chunks));
  }
  Future<SpatialPayload<PointCloudData>> load(
    SpatialChunk chunk,
    LoadCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final data = chunks[chunk.id];
    if (data == null ||
        data.sourceUri != chunk.uri ||
        data.sourceVersion != chunk.version) {
      throw StateError('Chunk source version does not match the hierarchy.');
    }
    return SpatialPayload(
      data,
      decodedBytes: data.payloadBytes,
      gpuBytes: data.count * 12,
    );
  }
}

/// Attach to one viewport. Loads invalidate that viewport; settled scenes do not
/// retain frame demand. Rendering and source queries share the filtered LOD cut.
final class PointCloudStreamPlugin extends ScenePlugin {
  final SpatialStreamer<PointCloudData> stream;
  final Group object;
  final PointsMaterial material;
  final String instanceId;
  final bool closeStreamOnDetach;
  final _clouds = <String, ScenePointCloud>{};
  Registration? _changes;
  bool _dirty = true;
  int _streamRevision = -1;
  PointCloudFilter _filter = PointCloudFilter();
  PointCloudStreamPlugin({
    required this.stream,
    this.instanceId = 'default',
    Group? object,
    PointsMaterial? material,
    this.closeStreamOnDetach = true,
  }) : object = object ?? Group(name: 'streamed points'),
       material = material ?? PointsMaterial();
  @override
  String get id => 'zyren.pointclouds.stream.$instanceId';
  PointCloudFilter get filter => _filter;
  set filter(PointCloudFilter value) {
    _filter = value;
    _dirty = true;
    _invalidate?.call();
  }

  void Function()? _invalidate;
  Map<String, ScenePointCloud> get visibleClouds => Map.unmodifiable(_clouds);
  @override
  void attach(PluginContext context) {
    _invalidate = context.invalidate;
    context.scene.add(object);
    _changes = stream.onChanged(() {
      _dirty = true;
      context.invalidate();
    });
  }

  /// Also usable by hosts that run their own frame loop.
  void update(Camera camera, PhysicalSize size) {
    stream.update(camera, size, transform: object.worldMatrix);
    if (!_dirty && _streamRevision == stream.revision) return;
    _streamRevision = stream.revision;
    final visible = stream.visible;
    for (final cloud in _clouds.values) {
      cloud.close();
    }
    _clouds.clear();
    for (final entry in visible.entries) {
      final selected = [
        for (var i = 0; i < entry.value.count; i++)
          if (_filter.accepts(entry.value, i)) i,
      ];
      if (selected.isEmpty) continue;
      final data = selected.length == entry.value.count
          ? entry.value
          : entry.value.select(selected);
      final cloud = ScenePointCloud(data: data, material: material);
      object.add(cloud.object);
      _clouds[entry.key] = cloud;
    }
    _dirty = false;
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) =>
      update(context.camera, PhysicalSize(frame.width, frame.height));
  PointCloudHit? pick(
    Ray ray, {
    required double radius,
    double near = 0,
    double far = double.infinity,
    Iterable<ClippingPlane> clippingPlanes = const [],
    LayerMask? layers,
  }) {
    PointCloudHit? best;
    for (final cloud in _clouds.values) {
      final hit = cloud.pick(
        ray,
        radius: radius,
        near: near,
        far: far,
        clippingPlanes: clippingPlanes,
        layers: layers,
      );
      if (hit != null &&
          (best == null ||
              hit.distance < best.distance ||
              hit.distance == best.distance &&
                  hit.identity.$3 < best.identity.$3)) {
        best = hit;
      }
    }
    return best;
  }

  @override
  Future<void> detach(PluginContext context) async {
    _changes?.dispose();
    _changes = null;
    _invalidate = null;
    for (final c in _clouds.values) {
      c.close();
    }
    _clouds.clear();
    object.parent?.remove(object);
    if (closeStreamOnDetach) await stream.close();
  }
}
