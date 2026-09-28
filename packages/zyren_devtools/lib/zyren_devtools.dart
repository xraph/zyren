library;

import 'dart:collection';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

part 'src/diagnostics.dart';

const sceneDevtools = ServiceKey<SceneDevtoolsPlugin>('zyren.devtools');

/// Copied inspection values. IDs are local to one inspector instance.
final class SceneNodeInfo {
  final int id, depth;
  final int? parentId, geometryId;
  final String? name;
  final bool isMesh, visible, effectivelyVisible;
  final Vec3 position, scale;
  final Quat rotation;
  final int triangles;
  final BufferGeometry? _geometry;
  final bool _hasColorMap;
  final Color3? color;
  final bool? unlit;
  SceneNodeInfo._(
    Object3D object, {
    required this.id,
    required this.parentId,
    required this.depth,
    required this.effectivelyVisible,
  }) : _geometry = object is Mesh ? object.geometry : null,
       _hasColorMap = object is Mesh && object.material.colorMap != null,
       name = object.name,
       isMesh = object is Mesh,
       position = object.position,
       scale = object.scale,
       rotation = object.quaternion,
       visible = object.visible,
       triangles = object is Mesh ? object.geometry.indices.length ~/ 3 : 0,
       geometryId = object is Mesh ? object.geometry.id : null,
       color = object is Mesh ? object.material.color : null,
       unlit = object is Mesh ? object.material.unlit : null;
}

final class SceneInspection {
  final int revision;
  final List<SceneNodeInfo> nodes;
  SceneInspection._(this.revision, Iterable<SceneNodeInfo> nodes)
    : nodes = List.unmodifiable(nodes);
}

/// CPU scene inspection and a bounded history of reported backend statistics.
class SceneDevtoolsPlugin extends ScenePlugin {
  @override
  String get id => 'zyren.devtools';
  final int historyLimit;
  final _ids = Expando<int>('inspector object IDs');
  final _frames = Queue<FrameStats>();
  int _nextId = 1;
  int _attachment = 0;
  PluginContext? _context;
  SceneDevtoolsPlugin({this.historyLimit = 120}) {
    if (historyLimit < 1) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
  }
  bool get isAttached => _context != null;
  List<FrameStats> get frames => List.unmodifiable(_frames);
  DeviceCapabilities get capabilities => _attached.capabilities;
  PluginContext get _attached =>
      _context ??
      (throw StateError('Attach the inspector before querying it.'));

  @override
  void attach(PluginContext context) {
    _attachment++;
    _context = context;
    context.provide(sceneDevtools, this);
  }

  SceneInspection snapshot({int? maxNodes}) {
    if (maxNodes != null && maxNodes < 1) {
      throw ArgumentError.value(maxNodes, 'maxNodes');
    }
    final scene = _attached.scene;
    final nodes = <SceneNodeInfo>[];
    final pending = <(Object3D, int?, int, bool)>[
      for (final child in scene.children.reversed)
        (child, null, 0, scene.visible),
    ];
    while (pending.isNotEmpty) {
      if (maxNodes != null && nodes.length == maxNodes) {
        throw const DiagnosticException(
          'sceneTooLarge',
          'Scene exceeds the 10000 node inspection budget.',
        );
      }
      final (object, parentId, depth, parentVisible) = pending.removeLast();
      final id = _ids[object] ??= _nextId++;
      final visible = parentVisible && object.visible;
      nodes.add(
        SceneNodeInfo._(
          object,
          id: id,
          parentId: parentId,
          depth: depth,
          effectivelyVisible: visible,
        ),
      );
      for (final child in object.children.reversed) {
        pending.add((child, id, depth + 1, visible));
      }
    }
    return SceneInspection._(scene.revision, nodes);
  }

  /// Resolves only objects still present in this scene; removed nodes are not retained.
  Object3D? objectFor(int id) {
    Object3D? visit(Object3D object) {
      if (_ids[object] == id) return object;
      for (final child in object.children) {
        final match = visit(child);
        if (match != null) return match;
      }
      return null;
    }

    return visit(_attached.scene);
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    _frames.addLast(stats);
    if (_frames.length > historyLimit) _frames.removeFirst();
  }

  @override
  void detach(PluginContext context) {
    _frames.clear();
    _context = null;
  }
}
