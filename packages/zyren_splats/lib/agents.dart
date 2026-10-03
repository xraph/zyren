import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_splats.dart';

/// Appearance estimates for source Gaussians in a named viewport.
/// Hosts may inspect source data before a GPU renderer is available.
final class GaussianAgentProvider extends AgentProvider {
  final GaussianCloudData Function() _data;
  GaussianCloudData get data => _data();
  final int Function()? _dataRevision;
  final bool Function()? _enabled;
  final Object3D object;
  final Vec3 sourceOrigin;
  final double minimumPixelVariance;
  final AgentViewportProvider view;
  @override
  final String instanceId;
  GaussianAgentProvider({
    required GaussianCloudData data,
    required this.object,
    required this.view,
    required this.instanceId,
    this.sourceOrigin = Vec3.zero,
    this.minimumPixelVariance = 0,
  }) : _data = (() => data),
       _dataRevision = null,
       _enabled = null;

  GaussianAgentProvider._scene(
    GaussianSplatPlugin renderer, {
    required this.view,
    required this.instanceId,
  }) : _data = (() => renderer.data),
       _dataRevision = (() => renderer.dataRevision),
       _enabled = (() => renderer.enabled),
       object = renderer.object,
       sourceOrigin = Vec3.zero,
       minimumPixelVariance = renderer.minimumPixelVariance;

  factory GaussianAgentProvider.forRenderer(
    GaussianSplatRenderer renderer, {
    required AgentViewportProvider view,
    required String instanceId,
  }) => GaussianAgentProvider(
    data: renderer.data,
    object: renderer.object,
    sourceOrigin: renderer.sourceOrigin,
    view: view,
    instanceId: instanceId,
  );

  factory GaussianAgentProvider.forScene(
    GaussianSplatPlugin renderer, {
    required AgentViewportProvider view,
    required String instanceId,
  }) => GaussianAgentProvider._scene(
    renderer,
    view: view,
    instanceId: instanceId,
  );

  @override
  String get id => 'zyren.splats';
  @override
  String get version => '0.1.0';
  @override
  int get revision => view.revision + (_dataRevision?.call() ?? 0);

  /// Bind disposal to your attachment scope or renderer's onClose callback.
  Registration register(
    AgentRegistry registry, {
    required void Function(void Function()) onClose,
  }) {
    final registration = registry.register(this);
    try {
      onClose(registration.dispose);
    } catch (_) {
      registration.dispose();
      rethrow;
    }
    return registration;
  }

  @override
  Map<String, Object?> get capabilities => const {
    'method': 'projected-Gaussian-opacity-estimate',
    'renderedPixelVisibility': 'unknown',
    'measurementSurface': false,
    'sorting': 'mean-depth-back-to-front',
    'streaming': 'single-resident-chunk',
    'lod': 'all-source-Gaussians',
    'mutations': false,
    'geospatialContext': 'unavailable',
    'tiles3dContext': 'unavailable',
  };
  @override
  List<AgentTool> get tools => supportedTools;
  static final List<AgentTool> supportedTools = List.unmodifiable([
    AgentTool(
      name: 'inspect',
      description:
          'Inspect Gaussian source identity, residency and query limits.',
      inputSchema: _schema({}),
      outputSchema: _outputSchema,
    ),
    AgentTool(
      name: 'estimate',
      description:
          'Estimate Gaussian opacity at logical viewport pixels. This is appearance evidence, not a measured surface or confirmed pixel.',
      inputSchema: _schema(
        {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
          'expectedFrameId': {'type': 'string', 'maxLength': 128},
          'expectedCameraRevision': {'type': 'integer', 'minimum': 0},
        },
        required: ['x', 'y'],
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
    Object3D root = object;
    var visible = _enabled?.call() ?? true;
    for (Object3D? node = object; node != null; node = node.parent) {
      visible = visible && node.visible;
      root = node;
    }
    if (!identical(root, view.scene)) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Gaussian object is no longer attached to this scene.',
      );
    }
    final viewportContext = Map<String, Object?>.from(
      view.invoke('context', const {}, context).data,
    )..remove('coverage');
    final result = <String, Object?>{
      'context': viewportContext,
      'runtimeId': object.id,
      'sourceUri': data.sourceUri.toString(),
      'sourceVersion': data.sourceVersion,
      'splatCount': data.splats.length,
      'coverage': capabilities,
      'units': view.units,
      'availableActions': <String>[],
      'unknowns': [
        'scene occlusion',
        'native screen presentation',
        'Flutter overlays',
        'section clipping',
        'intersecting-Gaussian order',
      ],
    };
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, data: result, revision: revision);
    }
    if (tool != 'estimate') return AgentResult(AgentStatus.unsupported);
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
    if (!metrics.isUsable ||
        !metrics.devicePixelRatio.isFinite ||
        metrics.devicePixelRatio <= 0) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Viewport extent or DPR is unavailable.',
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
    final width = (metrics.width * metrics.devicePixelRatio).round(),
        height = (metrics.height * metrics.devicePixelRatio).round();
    if (width < 1 || height < 1 || width > 16384 || height > 16384) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Viewport exceeds the projection budget.',
      );
    }
    final projected = visible
        ? projectGaussians(
            data,
            camera: camera,
            size: PhysicalSize(width, height),
            transform: object.worldMatrix,
            sourceOrigin: sourceOrigin,
            minimumPixelVariance: minimumPixelVariance,
          )
        : <ProjectedGaussian>[];
    final hits = <Map<String, Object?>>[];
    final limit = arguments['limit'] as int? ?? 1;
    var count = 0;
    // Return nearest means first; blending itself uses the reverse order.
    for (final p in projected.reversed) {
      context.checkCancelled();
      final alpha = p.alphaAt(
        x / metrics.width * width - (p.center.x + 1) * width / 2,
        (1 - p.center.y) * height / 2 - y / metrics.height * height,
      );
      if (alpha <= 0) continue;
      count++;
      if (hits.length >= limit) continue;
      hits.add({
        'recordIndex': p.recordIndex,
        'sourceMean': _vector(p.source.mean),
        'estimatedOpacity': alpha,
        'meanDepth': p.depth,
        'sourceUri': data.identityAt(p.dataIndex).$1.toString(),
        'sourceVersion': data.identityAt(p.dataIndex).$2,
        'runtimeId': object.id,
        'classification': null,
        'measurementSurface': false,
        'renderedPixelVisibility': 'unknown',
        'availableActions': <String>[],
      });
    }
    result['point'] = {
      'x': x,
      'y': y,
      'coordinateSpace': 'viewport-local-logical-top-left',
    };
    result['projectionSize'] = {
      'width': width,
      'height': height,
      'evidence': 'logical-extent-times-DPR',
    };
    result['hits'] = hits;
    result['truncated'] = count > limit;
    return AgentResult(
      hits.isEmpty ? AgentStatus.empty : AgentStatus.ok,
      data: result,
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
    'splatCount': {'type': 'integer', 'minimum': 1},
    'hits': {
      'type': 'array',
      'maxItems': 32,
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
