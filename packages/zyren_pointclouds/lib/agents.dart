import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_pointclouds.dart';

/// Optional shared-registry provider for one cloud in a named host viewport.
final class PointCloudAgentProvider extends AgentProvider {
  final ScenePointCloud cloud;
  final AgentViewportProvider view;
  @override
  final String instanceId;
  PointCloudAgentProvider({
    required this.cloud,
    required this.view,
    required this.instanceId,
  });
  @override
  String get id => 'zyren.pointclouds';
  @override
  String get version => '0.1.0';
  @override
  int get revision => view.revision;

  Registration register(AgentRegistry registry) {
    if (cloud.isClosed) throw StateError('Point cloud has closed.');
    final registration = registry.register(this);
    cloud.onClose(registration.dispose);
    return registration;
  }

  @override
  Map<String, Object?> get capabilities => const {
    'method': 'source-point-radius',
    'renderedPixelVisibility': 'unknown',
    'classifications': 'source-byte-or-unknown',
    'streaming': 'single-resident-chunk',
    'lod': 'full-source-samples',
    'mutations': false,
    'geospatialContext': 'unavailable',
    'tiles3dContext': 'unavailable',
  };
  @override
  late final List<AgentTool> tools = List.unmodifiable([
    AgentTool(
      name: 'inspect',
      description:
          'Inspect resident source points, payload limits and known classifications.',
      inputSchema: _schema({}),
      outputSchema: _outputSchema,
    ),
    AgentTool(
      name: 'pick',
      description:
          'Query source points from logical viewport pixels with a world-unit radius. Native pixel occlusion is unknown.',
      inputSchema: _schema(
        {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'radius': {'type': 'number', 'minimum': 1e-12},
          'expectedFrameId': {'type': 'string', 'maxLength': 128},
          'expectedCameraRevision': {'type': 'integer', 'minimum': 0},
        },
        required: ['x', 'y', 'radius'],
      ),
      outputSchema: _outputSchema,
    ),
  ]);

  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    Object3D root = cloud.object;
    while (root.parent != null) {
      root = root.parent!;
    }
    if (cloud.isClosed || !identical(root, view.scene)) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Point cloud is no longer attached to this scene.',
      );
    }
    final viewportContext = Map<String, Object?>.from(
      view.invoke('context', const {}, context).data,
    )..remove('coverage');
    final data = <String, Object?>{
      'context': viewportContext,
      'runtimeId': cloud.object.id,
      'sourceUri': cloud.data.sourceUri.toString(),
      'sourceVersion': cloud.data.sourceVersion,
      'units': view.units,
      'pointCount': cloud.data.count,
      'coordinateBytes': cloud.data.coordinateBytes,
      'classificationBytes': cloud.data.classificationBytes,
      'maxLocalDisplayError': cloud.maxDisplayError,
      'coverage': capabilities,
      'unknowns': [
        'other-object occlusion',
        'native marker footprint',
        'Flutter overlays',
        'unloaded source data',
      ],
      'availableActions': <String>[],
    };
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, data: data, revision: revision);
    }
    if (tool != 'pick') return AgentResult(AgentStatus.unsupported);
    final camera = view.camera(), metrics = view.viewport();
    if (arguments['expectedCameraRevision'] case final int expected) {
      if (expected != camera.revision) {
        return AgentResult(AgentStatus.stale, message: 'Camera changed.');
      }
    }
    if (arguments['expectedFrameId'] case final String expected) {
      final frame = viewportContext['presentedFrame'] as Map?;
      if (frame == null) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Presented frame is unknown.',
        );
      }
      if (frame['id'] != expected ||
          viewportContext['frameCorrelation'] != 'matches-current-state') {
        return AgentResult(
          AgentStatus.stale,
          message: 'Presented frame does not match this query.',
        );
      }
    }
    if (!metrics.isUsable) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Viewport extent is unavailable.',
      );
    }
    final x = (arguments['x'] as num).toDouble(),
        y = (arguments['y'] as num).toDouble();
    if (x < 0 || y < 0 || x > metrics.width || y > metrics.height) {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Point is outside the viewport.',
      );
    }
    if (camera is! OrthographicCamera && camera is! PerspectiveCamera) {
      return AgentResult(
        AgentStatus.unsupported,
        message:
            'Camera clipping is supported for orthographic and perspective cameras.',
      );
    }
    final point = ViewportPoint(
      x,
      y,
    ).toNdc(logicalWidth: metrics.width, logicalHeight: metrics.height);
    final cameraRay = camera.rayFromNdc(point.x, point.y, metrics.aspect);
    final forward = (camera.target - camera.position).normalized();
    final cosine = cameraRay.direction.dot(forward);
    final near = camera is OrthographicCamera
        ? camera.near
        : (camera as PerspectiveCamera).near;
    final far = camera is OrthographicCamera
        ? camera.far
        : (camera as PerspectiveCamera).far;
    final hit = cloud.pick(
      Ray(cameraRay.origin, cameraRay.direction),
      radius: (arguments['radius'] as num).toDouble(),
      near: near / cosine,
      far: far / cosine,
      layers: camera.layers,
      clippingPlanes: view.scene.clippingPlanes,
    );
    data['point'] = {
      'x': x,
      'y': y,
      'coordinateSpace': 'viewport-local-logical-top-left',
    };
    data['hits'] = [
      if (hit != null)
        {
          'recordIndex': hit.identity.$3,
          'sourcePoint': _vector(hit.sourcePoint),
          'worldPoint': _vector(hit.worldPoint),
          'distance': hit.distance,
          'raySeparation': hit.raySeparation,
          'classification': cloud.data.classificationAt(hit.dataIndex),
          'sourceUri': hit.identity.$1.toString(),
          'sourceVersion': hit.identity.$2,
          'runtimeId': cloud.object.id,
          'renderedPixelVisibility': 'unknown',
          'availableActions': <String>[],
        },
    ];
    return AgentResult(
      hit == null ? AgentStatus.empty : AgentStatus.ok,
      data: data,
      revision: revision,
    );
  }
}

Map<String, Object?> _schema(
  Map<String, Object?>? properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': ?properties,
  'additionalProperties': properties == null,
  if (required.isNotEmpty) 'required': required,
};
List<double> _vector(Vec3 p) => [p.x, p.y, p.z];

final _outputSchema = <String, Object?>{
  'type': 'object',
  'required': [
    'context',
    'runtimeId',
    'sourceUri',
    'sourceVersion',
    'coverage',
  ],
  'properties': {
    'context': {'type': 'object'},
    'runtimeId': {'type': 'integer', 'minimum': 1},
    'sourceUri': {'type': 'string'},
    'sourceVersion': {'type': 'string', 'minLength': 1, 'maxLength': 1024},
    'coverage': {'type': 'object'},
    'pointCount': {'type': 'integer', 'minimum': 1},
    'hits': {
      'type': 'array',
      'maxItems': 1,
      'items': {
        'type': 'object',
        'required': [
          'recordIndex',
          'sourceUri',
          'sourceVersion',
          'runtimeId',
          'renderedPixelVisibility',
        ],
        'properties': {
          'recordIndex': {'type': 'integer', 'minimum': 0},
          'sourceUri': {'type': 'string'},
          'sourceVersion': {'type': 'string'},
          'runtimeId': {'type': 'integer', 'minimum': 1},
          'renderedPixelVisibility': {
            'type': 'string',
            'enum': ['unknown'],
          },
        },
      },
    },
  },
};
