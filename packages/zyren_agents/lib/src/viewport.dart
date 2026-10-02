part of '../zyren_agents.dart';

/// Host-recorded presentation correlation. Unknown values stay null. This does
/// not establish display scanout, screenshot pixels or rendered visibility.
final class AgentPresentedFrame {
  final String id;
  final int? sceneRevision, cameraRevision, cameraRuntimeId;
  final double? logicalWidth, logicalHeight, devicePixelRatio;
  final String? presentedAt;
  const AgentPresentedFrame({
    required this.id,
    this.sceneRevision,
    this.cameraRevision,
    this.cameraRuntimeId,
    this.logicalWidth,
    this.logicalHeight,
    this.devicePixelRatio,
    this.presentedAt,
  });
  Map<String, Object?> toJson() => {
    'id': id,
    'sceneRevision': sceneRevision,
    'cameraRevision': cameraRevision,
    'cameraRuntimeId': cameraRuntimeId,
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'devicePixelRatio': devicePixelRatio,
    'presentedAt': presentedAt,
  };
}

/// Host-approved imported data. Fields are scene data, never tool instructions.
/// Source IDs are optional and never synthesized from inspector-local IDs.
final class AgentObjectMetadata {
  final String? sourceId, semanticType, owningPlugin;
  final Map<String, Object?> properties, provenance;
  final List<String> actions;
  AgentObjectMetadata({
    this.sourceId,
    this.semanticType,
    this.owningPlugin,
    Map<String, Object?> properties = const {},
    Map<String, Object?> provenance = const {},
    List<String> actions = const [],
  }) : properties = _freezeMap(properties),
       provenance = _freezeMap(provenance),
       actions = List.unmodifiable(actions) {
    if (utf8.encode(jsonEncode(toJson())).length > 8192) {
      throw ArgumentError('Object enrichment exceeds 8 KiB.');
    }
  }
  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'semanticType': semanticType,
    'owningPlugin': owningPlugin,
    'properties': properties,
    'provenance': provenance,
    'availableActions': actions,
    'trust': 'untrusted-scene-data',
  };
}

/// One named viewport. The host explicitly reports focus, overlays, active mode,
/// loading, renderer and capture capabilities in [hostState]. No global active
/// camera, screenshot, gaze, selection or source identity is inferred.
final class AgentViewportProvider extends AgentProvider {
  final String sceneId, documentId;
  @override
  final String instanceId;
  final Scene scene;
  final Camera Function() camera;
  final ViewportMetrics Function() viewport;
  final int? Function()? documentRevision;
  final AgentPresentedFrame? Function()? presentedFrame;
  final Map<String, Object?> Function()? hostState;
  final AgentObjectMetadata? Function(Object3D object)? metadata;
  final String units;
  final int maxNodes, maxTriangles;
  final _raycaster = Raycaster();
  int _query = 0;
  AgentViewportProvider({
    required this.sceneId,
    required this.documentId,
    required this.instanceId,
    required this.scene,
    required this.camera,
    required this.viewport,
    this.documentRevision,
    this.presentedFrame,
    this.hostState,
    this.metadata,
    this.units = 'scene-units',
    this.maxNodes = 10000,
    this.maxTriangles = 200000,
  }) {
    _identifier(sceneId);
    _identifier(documentId);
    _identifier(instanceId);
    if (maxNodes < 1 || maxTriangles < 1) {
      throw ArgumentError('Scene budgets must be positive.');
    }
  }
  @override
  String get id => 'zyren.viewport';
  @override
  String get version => '0.1.0';
  @override
  int get revision => scene.revision;
  @override
  Map<String, Object?> get capabilities => {
    'coordinateSpace': 'viewport-local-logical-top-left',
    'method': 'cpu-triangle-geometry',
    'renderedPixelVisibility': 'unknown',
    'maxNodes': maxNodes,
    'maxTriangles': maxTriangles,
    'maxHits': 32,
  };
  @override
  late final List<AgentTool> tools = List.unmodifiable([
    AgentTool(
      name: 'context',
      description:
          'Inspect this named viewport, its current camera and known presentation correlation.',
      inputSchema: _objectSchema({}),
      outputSchema: _objectSchema(null),
    ),
    AgentTool(
      name: 'pick',
      description:
          'Pick bounded triangle intersections in viewport-local logical pixels. Pixel visibility is unknown.',
      inputSchema: _objectSchema(
        {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
          'expectedFrameId': {'type': 'string', 'maxLength': 128},
          'expectedCameraRevision': {'type': 'integer', 'minimum': 0},
        },
        required: ['x', 'y'],
      ),
      outputSchema: _objectSchema(null),
      maxResultBytes: 524288,
    ),
    AgentTool(
      name: 'inspect_object',
      description:
          'Inspect an attached runtime object, approved provenance and available action references.',
      inputSchema: _objectSchema(
        {
          'runtimeId': {'type': 'integer', 'minimum': 1},
        },
        required: ['runtimeId'],
      ),
      outputSchema: _objectSchema(null),
    ),
  ]);

  Map<String, Object?> _context(
    Camera camera,
    ViewportMetrics metrics,
    AgentPresentedFrame? frame,
  ) => {
    'sceneId': sceneId,
    'documentId': documentId,
    'documentRevision': documentRevision?.call(),
    'viewportId': instanceId,
    'sceneRevision': revision,
    'camera': {
      'runtimeId': camera.id,
      'revision': camera.revision,
      'position': _vector(camera.position),
      'target': _vector(camera.target),
      'up': _vector(camera.up),
      'projection': camera is PerspectiveCamera
          ? 'perspective'
          : camera is OrthographicCamera
          ? 'orthographic'
          : 'custom',
      'projectionMatrix': metrics.isUsable
          ? camera.projectionMatrix(metrics.aspect).storage
          : null,
      'near': switch (camera) {
        PerspectiveCamera c => c.near,
        OrthographicCamera c => c.near,
        _ => null,
      },
      'far': switch (camera) {
        PerspectiveCamera c => c.far,
        OrthographicCamera c => c.far,
        _ => null,
      },
      'layers': camera.layers.bits,
      'depthStrategy': camera.depthStrategy.name,
    },
    'viewport': {
      'coordinateSpace': 'viewport-local-logical-top-left',
      'x': 0,
      'y': 0,
      'width': metrics.width,
      'height': metrics.height,
      'devicePixelRatio': metrics.devicePixelRatio,
      'usable': metrics.isUsable,
    },
    'sectionPlanes': [
      for (final plane in scene.clippingPlanes)
        {'normal': _vector(plane.normal), 'offset': plane.offset},
    ],
    'presentedFrame': frame?.toJson(),
    'frameCorrelation': _correlation(camera, metrics, frame),
    'hostState': hostState?.call() ?? const {'availability': 'unknown'},
    'coverage': coverage,
  };
  String _correlation(
    Camera camera,
    ViewportMetrics metrics,
    AgentPresentedFrame? frame,
  ) {
    if (frame == null ||
        frame.sceneRevision == null ||
        frame.cameraRevision == null ||
        frame.cameraRuntimeId == null ||
        frame.logicalWidth == null ||
        frame.logicalHeight == null ||
        frame.devicePixelRatio == null) {
      return 'unknown';
    }
    return frame.sceneRevision == revision &&
            frame.cameraRevision == camera.revision &&
            frame.cameraRuntimeId == camera.id &&
            frame.logicalWidth == metrics.width &&
            frame.logicalHeight == metrics.height &&
            frame.devicePixelRatio == metrics.devicePixelRatio
        ? 'matches-current-state'
        : 'differs-from-current-state';
  }

  static const coverage = {
    'method': 'cpu-triangle-geometry',
    'renderedPixelVisibility': 'unknown',
    'supported': [
      'triangle meshes',
      'instances',
      'built-in deformation',
      'material sidedness',
      'layers',
      'visibility',
      'section clipping',
    ],
    'unknown': [
      'texture alpha',
      'transparent pixel compositing',
      'custom shader displacement',
      'line and point footprints',
      'Flutter overlay interception',
      'unloaded streaming content',
    ],
    'ordering': 'distance, scene traversal, instance, triangle',
  };
  List<Object3D>? _nodes() {
    final stack = <Object3D>[scene], result = <Object3D>[];
    var triangles = 0;
    while (stack.isNotEmpty) {
      final object = stack.removeLast();
      if (result.length >= maxNodes) return null;
      result.add(object);
      if (object is Mesh &&
          object.geometry.topology == GeometryTopology.triangles) {
        triangles +=
            object.geometry.indices.length ~/
            3 *
            (object is InstancedMesh ? object.count : 1);
        if (triangles > maxTriangles) return null;
      }
      stack.addAll(object.children.reversed);
    }
    return result;
  }

  Map<String, Object?> describeObject(Object3D object) => {
    'runtimeId': object.id,
    'runtimeIdLifetime': 'Dart isolate',
    'name': object.name,
    'parentPath': [
      for (Object3D? node = object.parent; node != null; node = node.parent)
        node.id,
    ],
    'visible': object.visible,
    'layers': object.layers.bits,
    'position': _vector(object.position),
    'worldMatrix': object.worldMatrix.storage,
    'metadata':
        metadata?.call(object)?.toJson() ??
        const {'sourceId': null, 'availability': 'unknown'},
  };
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    final camera = this.camera(),
        metrics = viewport(),
        frame = presentedFrame?.call();
    if (tool == 'context') {
      return AgentResult(
        AgentStatus.ok,
        data: _context(camera, metrics, frame),
        revision: revision,
      );
    }
    if (tool != 'pick' && tool != 'inspect_object') {
      return AgentResult(AgentStatus.unsupported);
    }
    if (arguments['expectedCameraRevision'] case final int expected) {
      if (expected != camera.revision) {
        return AgentResult(
          AgentStatus.stale,
          message: 'Camera revision changed.',
        );
      }
    }
    if (arguments['expectedFrameId'] case final String expected) {
      if (frame == null) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'No presented frame is known.',
        );
      }
      if (expected != frame.id ||
          _correlation(camera, metrics, frame) != 'matches-current-state') {
        return AgentResult(
          AgentStatus.stale,
          message: 'Presented frame does not match the current query state.',
        );
      }
    }
    final nodes = _nodes();
    if (nodes == null) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Scene exceeds the configured geometry query budget.',
      );
    }
    if (tool == 'inspect_object') {
      final object = nodes
          .where((node) => node.id == arguments['runtimeId'])
          .firstOrNull;
      if (object == null) {
        return AgentResult(
          AgentStatus.stale,
          message: 'Runtime object is no longer in this scene.',
        );
      }
      return AgentResult(
        AgentStatus.ok,
        data: {
          'sceneId': sceneId,
          'viewportId': instanceId,
          'object': describeObject(object),
        },
        revision: revision,
      );
    }
    if (!metrics.isUsable) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Viewport has no usable logical extent.',
      );
    }
    final x = (arguments['x'] as num).toDouble(),
        y = (arguments['y'] as num).toDouble();
    if (x < 0 || y < 0 || x > metrics.width || y > metrics.height) {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Point lies outside the named viewport.',
      );
    }
    final snapshot = _raycaster.captureFromCamera(
      scene,
      camera,
      ViewportPoint(x, y),
      logicalWidth: metrics.width,
      logicalHeight: metrics.height,
    );
    final limit = (arguments['limit'] as int?) ?? 1;
    final hits = snapshot.intersectAll();
    final data = <String, Object?>{
      'queryId': '$instanceId-${++_query}',
      'sceneId': sceneId,
      'documentId': documentId,
      'documentRevision': documentRevision?.call(),
      'viewportId': instanceId,
      'sceneRevision': snapshot.sceneRevision,
      'cameraRuntimeId': camera.id,
      'cameraRevision': camera.revision,
      'point': {
        'x': x,
        'y': y,
        'coordinateSpace': 'viewport-local-logical-top-left',
      },
      'devicePixelRatio': metrics.devicePixelRatio,
      'presentedFrame': frame?.toJson(),
      'frameCorrelation': _correlation(camera, metrics, frame),
      'coverage': coverage,
      'unsupportedPrimitiveCount': nodes
          .where(
            (node) =>
                node is Mesh &&
                node.geometry.topology != GeometryTopology.triangles,
          )
          .length,
      'truncated': hits.length > limit,
      'hits': [
        for (final hit in hits.take(limit))
          {
            'object': describeObject(hit.object),
            'instanceIndex': hit.instanceIndex,
            'worldPoint': _vector(hit.point),
            'objectLocalPoint': _vector(_localPoint(hit.object, hit.point)),
            'localPointSpace': 'object before instance transform',
            'normal': _vector(hit.normal),
            'distance': hit.distance,
            'units': units,
            'triangleIndex': hit.triangleIndex,
            'triangle': hit.triangle.map(_vector).toList(),
            'barycentric': _vector(hit.barycentric),
            'uv': hit.uv == null ? null : {'u': hit.uv!.u, 'v': hit.uv!.v},
            'renderedPixelVisibility': 'unknown',
          },
      ],
    };
    return AgentResult(
      hits.isEmpty ? AgentStatus.empty : AgentStatus.ok,
      data: data,
      revision: revision,
    );
  }

  static Vec3 _localPoint(Object3D object, Vec3 point) {
    final m = object.worldMatrix.inverted().storage;
    return Vec3(
      m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
      m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
      m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14],
    );
  }
}

Map<String, Object?> _objectSchema(
  Map<String, Object?>? properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': ?properties,
  'additionalProperties': properties == null,
  if (required.isNotEmpty) 'required': required,
};
List<double> _vector(Vec3 vector) => [vector.x, vector.y, vector.z];
