part of '../zyren_devtools.dart';

/// Stable failures shared by the in-process, CLI and MCP interfaces.
final class DiagnosticException implements Exception {
  final String code, message;
  const DiagnosticException(this.code, this.message);
  Map<String, Object?> toJson() => {'code': code, 'message': message};
  @override
  String toString() => '$code: $message';
}

/// Read-only, versioned access to one inspector. No model or transport required.
final class SceneDiagnostics {
  static const schemaVersion = 1;
  static const packageVersion = '0.1.0';
  final SceneDevtoolsPlugin inspector;
  final int issueLimit;
  final _issues = Queue<Map<String, Object?>>();
  final _bounds = Expando<List<Vec3>>('immutable geometry bounds');
  final String _session =
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${math.Random.secure().nextInt(1 << 32).toRadixString(36)}';
  SceneDiagnostics(this.inspector, {this.issueLimit = 100}) {
    if (issueLimit < 1 || issueLimit > 1000) {
      throw ArgumentError.value(issueLimit, 'issueLimit');
    }
  }

  /// Feed the host's issue stream, including initialization/presentation failures.
  /// Causes and source URIs are omitted because they can contain private data.
  void recordIssue(SceneIssue issue) {
    _issues.add({
      'code': _text(issue.code),
      'message': _text(issue.message),
      'operation': _text(issue.operation),
      'severity': issue.severity.name,
      'pluginId': _text(issue.pluginId),
      'backend': _text(issue.backend),
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'attachment': inspector._attachment,
      'requiredFeatures': issue.requiredFeatures.map((f) => f.name).toList()
        ..sort(),
    });
    if (_issues.length > issueLimit) _issues.removeFirst();
  }

  static final List<Map<String, Object?>> tools = List.unmodifiable([
    _tool(
      'inspect_scene',
      'Read a page of current scene nodes. Require expectedRevision on subsequent pages.',
      {
        'offset': _integer(0, 10000),
        'limit': _integer(1, 1000),
        'expectedRevision': _integer(0, null),
      },
    ),
    _tool(
      'inspect_object',
      'Read one current object by its session-local integer ID.',
      {'id': _integer(1, null)},
      required: ['id'],
    ),
    _tool(
      'get_renderer_capabilities',
      'Read features and enforced limits reported by this renderer.',
      {},
    ),
    _tool(
      'get_scene_issues',
      'Read bounded host issue history. Sources and exception objects are omitted.',
      {},
    ),
    _tool(
      'capture_frame_stats',
      'Read already recorded frames, not a new render or GPU capture. Unknown measurements are null.',
      {'limit': _integer(1, 1000)},
    ),
    _tool(
      'diagnose_scene',
      'Check blank-scene causes using visibility and conservative bounds. Pixel visibility remains unverified.',
      {
        'aspect': {'type': 'number', 'exclusiveMinimum': 0},
      },
    ),
    _tool(
      'export_report',
      'Capture bounded diagnostic metadata for a bug report. Does not include assets or a replay.',
      {
        'aspect': {'type': 'number', 'exclusiveMinimum': 0},
      },
    ),
  ]);

  Map<String, Object?> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) {
    final tool = tools.where((t) => t['name'] == name).firstOrNull;
    if (tool == null) {
      throw const DiagnosticException(
        'unknownTool',
        'Unknown diagnostic tool.',
      );
    }
    _validate(tool, arguments);
    final envelope = <String, Object?>{
      'schemaVersion': schemaVersion,
      'packageVersion': packageVersion,
      'sessionId': '$_session:${inspector._attachment}',
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'attached': inspector.isAttached,
    };
    if (name == 'get_scene_issues') {
      return {
        ...envelope,
        'issues': [
          for (final issue in _issues)
            {
              ...issue,
              'requiredFeatures': List<String>.from(
                issue['requiredFeatures'] as List,
              ),
            },
        ],
      };
    }
    if (!inspector.isAttached) {
      throw const DiagnosticException(
        'notAttached',
        'The scene inspector is not attached. Check host issues or wait for renderer readiness.',
      );
    }
    final data = switch (name) {
      'inspect_scene' => _scene(arguments),
      'inspect_object' => _object(arguments['id'] as int),
      'get_renderer_capabilities' => _capabilities(),
      'capture_frame_stats' => _frames(arguments['limit'] as int? ?? 120),
      'diagnose_scene' => _doctor((arguments['aspect'] as num?)?.toDouble()),
      'export_report' => {
        'scene': _scene({'limit': 1000}),
        'capabilities': _capabilities(),
        'diagnosis': _doctor((arguments['aspect'] as num?)?.toDouble()),
        'frameStats': _frames(120),
        'issues': [
          for (final issue in _issues)
            {
              ...issue,
              'requiredFeatures': List<String>.from(
                issue['requiredFeatures'] as List,
              ),
            },
        ],
        'includesAssets': false,
      },
      _ => throw StateError('Missing diagnostic handler.'),
    };
    return {...envelope, ...data};
  }

  SceneInspection _snapshot() => inspector.snapshot(maxNodes: 10000);
  Map<String, Object?> _scene(Map<String, Object?> args) {
    final snapshot = _snapshot();
    final expected = args['expectedRevision'];
    if (expected != null && expected != snapshot.revision) {
      throw const DiagnosticException(
        'staleRevision',
        'The scene changed. Restart pagination with a fresh revision.',
      );
    }
    final offset = args['offset'] as int? ?? 0;
    final limit = args['limit'] as int? ?? 100;
    final end = math.min(snapshot.nodes.length, offset + limit);
    return {
      'revision': snapshot.revision,
      'camera': _camera(),
      'root': {
        'visible': inspector._attached.scene.visible,
        'matrix': inspector._attached.scene.localMatrix.storage,
        'backgroundLinear': inspector._attached.scene.background?.toList(),
        'ambient': inspector._attached.scene.ambient,
        'lightDirection': inspector._attached.scene.lightDirection.storage,
      },
      'totalNodes': snapshot.nodes.length,
      'nodes': snapshot.nodes.skip(offset).take(limit).map(_node).toList(),
      'nextOffset': end < snapshot.nodes.length ? end : null,
    };
  }

  Map<String, Object?> _object(int id) {
    final snapshot = _snapshot();
    final node = snapshot.nodes.where((n) => n.id == id).firstOrNull;
    if (node == null) {
      throw const DiagnosticException(
        'objectNotFound',
        'Object is absent in this attachment. Inspect the scene again.',
      );
    }
    final worlds = _worlds(snapshot);
    return {
      'revision': snapshot.revision,
      'node': _node(node),
      'worldMatrix': worlds[id]!.storage,
    };
  }

  Map<String, Object?> _node(SceneNodeInfo n) => {
    'id': n.id,
    'parentId': n.parentId,
    'depth': n.depth,
    'name': _text(n.name),
    'type': n.isMesh ? 'mesh' : 'object',
    'visible': n.visible,
    'effectivelyVisible': n.effectivelyVisible,
    'position': n.position.storage,
    'scale': n.scale.storage,
    'quaternion': [n.rotation.x, n.rotation.y, n.rotation.z, n.rotation.w],
    'geometryId': n.geometryId,
    'triangles': n.triangles,
    'material': n.isMesh
        ? {
            'colorLinear': n.color!.toList(),
            'unlit': n.unlit,
            'hasColorMap': n._hasColorMap,
          }
        : null,
  };

  Map<String, Object?> _camera() {
    final c = inspector._attached.camera;
    return {
      'type': c is PerspectiveCamera
          ? 'perspective'
          : c is OrthographicCamera
          ? 'orthographic'
          : 'custom',
      'revision': c.revision,
      'position': c.position.storage,
      'target': c.target.storage,
      'up': c.up.storage,
      if (c is PerspectiveCamera) ...{
        'near': c.near,
        'far': c.far,
        'zoom': c.zoom,
        'fieldOfViewRadians': c.fieldOfView,
      },
      if (c is OrthographicCamera) ...{
        'near': c.near,
        'far': c.far,
        'zoom': c.zoom,
        'left': c.left,
        'right': c.right,
        'top': c.top,
        'bottom': c.bottom,
      },
    };
  }

  Map<String, Object?> _capabilities() {
    final c = inspector.capabilities;
    return {
      'name': _text(c.name),
      'backend': _text(c.backend),
      'adapterName': _text(c.adapterName),
      'driverDescription': _text(c.driverDescription),
      'features': c.features.map((f) => f.name).toList()..sort(),
      'limits': {
        'maxTextureDimension2D': c.limits.maxTextureDimension2D,
        'maxGeometryBytes': c.limits.maxGeometryBytes,
        'sampleCounts': c.limits.sampleCounts.toList()..sort(),
      },
    };
  }

  Map<String, Object?> _frames(int limit) {
    final frames = inspector.frames;
    final selected = frames.skip(math.max(0, frames.length - limit)).toList();
    double? mean(Iterable<num> values) =>
        values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
    return {
      'availableFrames': frames.length,
      'sampleCount': selected.length,
      'measurementScope':
          'CPU times measure Dart snapshot construction and encoding. GPU and resident memory may be unavailable. This is retained history, not a timed FPS sample.',
      'summary': {
        'meanCpuBuildTimeUs': mean(
          selected.map((f) => f.cpuBuildTime.inMicroseconds),
        ),
        'meanCpuSubmitTimeUs': mean(
          selected.map((f) => f.cpuSubmitTime.inMicroseconds),
        ),
        'meanGpuTimeUs': mean(
          selected
              .where((f) => f.gpuTime != null)
              .map((f) => f.gpuTime!.inMicroseconds),
        ),
        'gpuMeasuredFrames': selected.where((f) => f.gpuTime != null).length,
      },
      'frames': [
        for (final f in selected)
          {
            'frameId': f.frameId,
            'surfaceEpoch': f.surfaceEpoch,
            'width': f.physicalSize.width,
            'height': f.physicalSize.height,
            'presentationPath': f.presentationPath.name,
            'cpuBuildTimeUs': f.cpuBuildTime.inMicroseconds,
            'cpuSubmitTimeUs': f.cpuSubmitTime.inMicroseconds,
            'gpuTimeUs': f.gpuTime?.inMicroseconds,
            'residentBytes': f.residentBytes,
            'drawCalls': f.drawCalls,
            'triangles': f.triangles,
            'readbackBytes': f.readbackBytes,
            'uploadedBytes': f.uploadedBytes,
            'coalescedFrames': f.coalescedFrames,
            'droppedFrames': f.droppedFrames,
          },
      ],
    };
  }

  Map<int, Mat4> _worlds(SceneInspection snapshot) {
    final worlds = <int, Mat4>{};
    for (final n in snapshot.nodes) {
      worlds[n.id] =
          (worlds[n.parentId] ?? inspector._attached.scene.localMatrix) *
          Mat4.compose(n.position, n.rotation, n.scale);
    }
    return worlds;
  }

  Map<String, Object?> _doctor(double? aspect) {
    final snapshot = _snapshot();
    final meshes = snapshot.nodes.where((n) => n.isMesh).toList();
    final visible = meshes.where((n) => n.effectivelyVisible).toList();
    final findings = <Map<String, Object?>>[];
    void add(
      String code,
      String message,
      String next, [
      List<int> ids = const [],
    ]) => findings.add({
      'code': code,
      'message': message,
      'nextAction': next,
      'objectIds': ids.take(100).toList(),
      'totalAffectedObjects': ids.length,
    });
    if (meshes.isEmpty) {
      add(
        'noMeshes',
        'The scene has no meshes.',
        'Add a Mesh with indexed geometry.',
      );
    }
    if (meshes.isNotEmpty && visible.isEmpty) {
      add(
        'allMeshesHidden',
        'All meshes inherit hidden visibility.',
        'Inspect the mesh and its ancestors, including the scene root.',
        meshes.map((n) => n.id).toList(),
      );
    }
    final frames = inspector.frames;
    if (frames.isEmpty) {
      add(
        'noRecordedFrames',
        'No successful frame has been recorded in this attachment.',
        'Check host issues and renderer readiness.',
      );
    }
    final source = inspector._attached.input;
    final input = source is ViewportInputSource ? source.viewport : null;
    aspect ??= input != null && input.isUsable ? input.aspect : null;
    aspect ??= frames.isEmpty
        ? null
        : frames.last.physicalSize.width / frames.last.physicalSize.height;
    if (aspect == null) {
      add(
        'viewportUnknown',
        'The viewport aspect ratio is unavailable.',
        'Pass aspect or wait for a frame before checking clip bounds.',
      );
    } else {
      try {
        final camera = inspector._attached.camera;
        final projection = camera.viewProjection(aspect).storage;
        final worlds = _worlds(snapshot);
        final outside = <int>[];
        for (final n in visible) {
          final corners = _bounds[n._geometry!] ??= _geometryCorners(
            n._geometry,
          );
          final world = worlds[n.id]!.storage;
          final clip = <List<double>>[];
          for (final v in corners) {
            final p = _transform(world, v);
            final r = Vec3(p[0], p[1], p[2]) - camera.position;
            final point = _transform(projection, r);
            if (point.any((v) => !v.isFinite)) {
              throw ArgumentError('Projection overflow.');
            }
            clip.add(point);
          }
          // A whole bounding box outside any homogeneous clip plane is excluded.
          // No perspective divide: boxes crossing the eye remain conservative.
          final excluded = <double Function(List<double>)>[
            (p) => p[0] + p[3],
            (p) => p[3] - p[0],
            (p) => p[1] + p[3],
            (p) => p[3] - p[1],
            (p) => p[2],
            (p) => p[3] - p[2],
          ].any((distance) => clip.every((p) => distance(p) < -1e-10));
          if (excluded) outside.add(n.id);
        }
        if (outside.isNotEmpty) {
          add(
            'outsideClipVolume',
            '${outside.length} visible mesh bounds are outside the camera clip volume.',
            'Inspect world transforms, camera target and clipping range.',
            outside,
          );
        }
      } on ArgumentError {
        add(
          'invalidCamera',
          'The camera or transformed bounds cannot be projected.',
          'Check the camera target, up vector and finite transform range.',
        );
      }
    }
    final caps = inspector.capabilities;
    final missing = <String>{};
    for (final n in visible) {
      for (final feature in [
        RenderFeature.indexedMeshes,
        if (n.unlit!)
          RenderFeature.unlitMaterials
        else
          RenderFeature.diffuseLighting,
        if (n._hasColorMap) RenderFeature.colorTextures,
      ]) {
        if (!caps.supports(feature)) missing.add(feature.name);
      }
    }
    if (missing.isNotEmpty) {
      add(
        'unsupportedMaterials',
        'Required renderer features are absent: ${(missing.toList()..sort()).join(', ')}.',
        'Use supported materials or a backend advertising those features.',
      );
    }
    if (frames.isNotEmpty && frames.last.readbackBytes > 0) {
      add(
        'readbackInUse',
        'The last frame copied pixels back to CPU memory.',
        'Compare with native presentation when investigating frame cost.',
      );
    }
    return {
      'revision': snapshot.revision,
      'cameraRevision': inspector._attached.camera.revision,
      'aspect': aspect,
      'meshCount': meshes.length,
      'visibleMeshCount': visible.length,
      'pixelVisibility': 'unverified',
      'findings': findings,
    };
  }
}

String? _text(String? value) => value == null
    ? null
    : value.length > 2048
    ? '${value.substring(0, 2048)}…'
    : value;
Map<String, Object?> _integer(int min, int? max) => {
  'type': 'integer',
  'minimum': min,
  'maximum': ?max,
};
Map<String, Object?> _tool(
  String name,
  String description,
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'name': name,
  'description': description,
  'inputSchema': {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  },
  'annotations': {
    'readOnlyHint': true,
    'destructiveHint': false,
    'idempotentHint': true,
    'openWorldHint': false,
  },
};
void _validate(Map<String, Object?> tool, Map<String, Object?> args) {
  final schema = tool['inputSchema'] as Map;
  final properties = schema['properties'] as Map;
  if (args.keys.any((k) => !properties.containsKey(k)) ||
      (schema['required'] as List).any((k) => !args.containsKey(k))) {
    throw const DiagnosticException(
      'invalidArguments',
      'Unknown or missing tool arguments. See tools/list.',
    );
  }
  for (final entry in args.entries) {
    final rule = properties[entry.key] as Map;
    final value = entry.value;
    if (value is! num ||
        !value.isFinite ||
        rule['type'] == 'integer' && value is! int ||
        rule['minimum'] != null && value < (rule['minimum'] as num) ||
        rule['maximum'] != null && value > (rule['maximum'] as num) ||
        rule['exclusiveMinimum'] != null &&
            value <= (rule['exclusiveMinimum'] as num)) {
      throw DiagnosticException(
        'invalidArguments',
        'Invalid ${entry.key}. See tools/list.',
      );
    }
  }
}

List<double> _transform(List<double> m, Vec3 p) => [
  for (var row = 0; row < 4; row++)
    m[row] * p.x + m[4 + row] * p.y + m[8 + row] * p.z + m[12 + row],
];
List<Vec3> _geometryCorners(BufferGeometry g) {
  final min = [double.infinity, double.infinity, double.infinity];
  final max = [
    double.negativeInfinity,
    double.negativeInfinity,
    double.negativeInfinity,
  ];
  for (var i = 0; i < g.positions.length; i++) {
    min[i % 3] = math.min(min[i % 3], g.positions[i]);
    max[i % 3] = math.max(max[i % 3], g.positions[i]);
  }
  return [
    for (final x in [min[0], max[0]])
      for (final y in [min[1], max[1]])
        for (final z in [min[2], max[2]]) Vec3(x, y, z),
  ];
}
