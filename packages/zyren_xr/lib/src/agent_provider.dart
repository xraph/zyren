import 'package:zyren_agents/zyren_agents.dart';

import '../zyren_xr.dart';

/// Host-supplied correlation. A sensor frame is separate from a presented frame.
final class XrViewBinding {
  final String sceneId, documentId, viewportId, cameraId;
  final int sceneRevision;
  final List<double> logicalRect;
  final double devicePixelRatio;
  final XrPose sceneFromSession;
  final int? presentedFrameId, presentedSceneRevision;
  final XrCalibration? calibration;

  XrViewBinding({
    required this.sceneId,
    required this.documentId,
    required this.viewportId,
    required this.cameraId,
    required this.sceneRevision,
    required List<double> logicalRect,
    required this.devicePixelRatio,
    required this.sceneFromSession,
    this.presentedFrameId,
    this.presentedSceneRevision,
    this.calibration,
  }) : logicalRect = List.unmodifiable(logicalRect) {
    if ([sceneId, documentId, viewportId, cameraId].any((v) => v.isEmpty) ||
        sceneRevision < 0 ||
        logicalRect.length != 4 ||
        logicalRect.any((v) => !v.isFinite) ||
        logicalRect[2] <= 0 ||
        logicalRect[3] <= 0 ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0) {
      throw ArgumentError('XR view identity and dimensions must be valid.');
    }
  }

  Map<String, Object?> toJson() => {
    'sceneId': sceneId,
    'documentId': documentId,
    'viewportId': viewportId,
    'cameraId': cameraId,
    'sceneRevision': sceneRevision,
    'logicalRect': logicalRect,
    'devicePixelRatio': devicePixelRatio,
    'sceneFromSession': sceneFromSession.matrix,
    'presentedFrameId': presentedFrameId,
    'presentedSceneRevision': presentedSceneRevision,
    'screenPointSpace': 'viewport-local-logical-top-left',
    'renderedPixelEvidence': 'unknown',
    'xrCameraPresentation':
        calibration != null &&
        calibration!.frameId == presentedFrameId &&
        presentedSceneRevision != null,
    'calibratedViewportProjection': calibration?.projection.storage,
    'presentedCameraTransform': calibration?.cameraPose.matrix,
    'presentedTimestamp': calibration?.timestamp,
    'presentationEpoch': calibration?.epoch,
  };

  bool sameView(XrViewBinding other) =>
      sceneId == other.sceneId &&
      documentId == other.documentId &&
      viewportId == other.viewportId &&
      cameraId == other.cameraId &&
      sceneRevision == other.sceneRevision &&
      devicePixelRatio == other.devicePixelRatio &&
      _equal(logicalRect, other.logicalRect) &&
      _equal(sceneFromSession.matrix, other.sceneFromSession.matrix);
}

bool _equal(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Normal application commands shared by UI and agents. Undo removes the last
/// placed native anchor. The host binds scene objects to returned anchor IDs.
final class XrPlacementCommands {
  final XrSession session;
  final _undo = <String>[];
  int _revision = 0;
  bool _busy = false;
  XrPlacementCommands(this.session);
  int get revision => _revision;
  bool get canUndo => _undo.isNotEmpty;

  Future<String> place({
    required XrPose pose,
    required int expectedRevision,
    required int expectedSessionRevision,
    required double expectedFrameTimestamp,
    required void Function() checkCurrent,
    String? expectedPresenterId,
    int? expectedPresentationEpoch,
  }) async {
    _begin(expectedRevision);
    try {
      if (_undo.length >= 128) {
        throw const XrException('anchorLimit', 'Placement history is full.');
      }
      final snapshot = await session.snapshot();
      checkCurrent();
      if (snapshot.revision != expectedSessionRevision) {
        throw const XrException('staleRevision', 'The native session changed.');
      }
      _requireTracking(snapshot);
      if (!expectedFrameTimestamp.isFinite ||
          expectedFrameTimestamp > snapshot.frame!.timestamp ||
          snapshot.frame!.timestamp - expectedFrameTimestamp > 0.5) {
        throw const XrException(
          'staleFrame',
          'Inspect a fresh XR frame before placement.',
        );
      }
      final anchor = await session.addAnchor(
        pose,
        expectedRevision: expectedSessionRevision,
        expectedFrameTimestamp: expectedFrameTimestamp,
        expectedPresenterId: expectedPresenterId,
        expectedPresentationEpoch: expectedPresentationEpoch,
      );
      _undo.add(anchor);
      _revision++;
      return anchor;
    } finally {
      _busy = false;
    }
  }

  Future<String> undo({
    required int expectedRevision,
    required void Function() checkCurrent,
  }) async {
    _begin(expectedRevision);
    try {
      if (_undo.isEmpty) {
        throw const XrException('empty', 'No placement to undo.');
      }
      final snapshot = await session.snapshot();
      checkCurrent();
      final id = _undo.last;
      await session.removeAnchor(id, expectedRevision: snapshot.revision);
      _undo.removeLast();
      _revision++;
      return id;
    } finally {
      _busy = false;
    }
  }

  void _begin(int expectedRevision) {
    if (_busy) {
      throw const XrException('busy', 'Another placement command is pending.');
    }
    if (expectedRevision != revision) {
      throw const XrException('staleRevision', 'Placement history changed.');
    }
    _busy = true;
  }
}

void _requireTracking(XrSnapshot snapshot) {
  if (snapshot.state != XrSessionState.running ||
      snapshot.frame?.tracking != XrTrackingState.normal) {
    throw const XrException(
      'trackingUnavailable',
      'Placement needs normal tracking.',
    );
  }
  if (snapshot.frame!.ageAt(snapshot.nativeTimestamp) > 0.5) {
    throw const XrException(
      'staleFrame',
      'The latest tracking frame is stale.',
    );
  }
}

final class XrAgentProvider extends AgentProvider {
  final XrPlacementCommands commands;
  final XrCapabilities deviceCapabilities;
  final XrViewBinding Function() view;
  final bool allowPlacement;
  final Future<XrRaycastResult> Function(double x, double y)? raycast;
  final _hits = <String, (XrRaycastResult, XrRaycastHit, XrViewBinding)>{};
  int _nextHit = 0;
  @override
  final String instanceId;
  bool _disposed = false;
  XrAgentProvider({
    required this.instanceId,
    required this.commands,
    required this.deviceCapabilities,
    required this.view,
    this.allowPlacement = false,
    this.raycast,
  });
  @override
  String get id => 'zyren.xr';
  @override
  String get version => '0.1.0';
  @override
  int get revision => commands.revision;
  @override
  Map<String, Object?> get capabilities => {
    'platform': deviceCapabilities.platform,
    'worldTracking': deviceCapabilities.worldTracking,
    'sceneDepthHardware': deviceCapabilities.sceneDepthHardware,
    'cameraPresentation': deviceCapabilities.cameraPresentation,
    'depthOcclusion': deviceCapabilities.depthOcclusion,
    'placementEnabledByHost': allowPlacement,
    'anchorIdentity': 'session-local-uuid',
    'units': 'metres',
    'matrices': 'column-major-right-handed',
    'screenRaycast': raycast == null
        ? 'unsupported'
        : 'native-plane-geometry-estimate',
    'pixelVisibility': 'unknown',
  };

  @override
  List<AgentTool> get tools => [
    if (raycast != null)
      AgentTool(
        name: 'screen_raycast',
        description:
            'Intersect a local logical screen point with native plane geometry using the presented camera. Hits are estimates, not pixel visibility.',
        inputSchema: _object(
          {
            'x': {'type': 'number', 'minimum': 0},
            'y': {'type': 'number', 'minimum': 0},
          },
          required: ['x', 'y'],
        ),
        outputSchema: {'type': 'object'},
        maxResultBytes: 32768,
      ),
    if (raycast != null)
      AgentTool(
        name: 'place_hit',
        readOnly: false,
        requiredScopes: {'xr.place'},
        description:
            'Place an anchor at a fresh native hit returned by screen_raycast. Uses the same ordinary placement command and undo history.',
        inputSchema: _object(
          {
            'hitToken': {'type': 'string', 'minLength': 1, 'maxLength': 256},
            'sceneRevision': _offset,
            'viewportId': {'type': 'string', 'minLength': 1, 'maxLength': 256},
          },
          required: ['hitToken', 'sceneRevision', 'viewportId'],
        ),
        outputSchema: _anchorOutput,
      ),
    AgentTool(
      name: 'inspect',
      description:
          'Read XR tracking, poses, bounded anchors and planes, light and view correlation. Sensor frames do not prove presented pixels.',
      inputSchema: _object({
        'anchorOffset': _offset,
        'planeOffset': _offset,
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
      }),
      outputSchema: _object(
        {
          'session': {'type': 'object'},
          'view': {'type': 'object'},
          'capabilities': {'type': 'object'},
          'availableActions': _strings,
        },
        required: ['session', 'view', 'capabilities', 'availableActions'],
      ),
      examples: const [
        {'limit': 16},
      ],
      maxResultBytes: 65536,
    ),
    AgentTool(
      name: 'place_anchor',
      readOnly: false,
      requiredScopes: {'xr.place'},
      description:
          'Place a session-local anchor using a rigid session-space transform and fresh inspected frame. The host binds scene content to the returned ID.',
      inputSchema: _object(
        {
          'transform': {
            'type': 'array',
            'minItems': 16,
            'maxItems': 16,
            'items': {'type': 'number'},
          },
          'sessionRevision': _offset,
          'sceneRevision': _offset,
          'frameTimestamp': {'type': 'number', 'minimum': 0},
          'viewportId': {'type': 'string', 'minLength': 1, 'maxLength': 256},
        },
        required: [
          'transform',
          'sessionRevision',
          'sceneRevision',
          'frameTimestamp',
          'viewportId',
        ],
      ),
      outputSchema: _anchorOutput,
    ),
    AgentTool(
      name: 'undo_placement',
      readOnly: false,
      requiredScopes: {'xr.place'},
      description:
          'Remove the last anchor placed through the shared XR commands. Reset or removed anchors return stale.',
      inputSchema: _object(
        {
          'sceneRevision': _offset,
          'viewportId': {'type': 'string', 'minLength': 1, 'maxLength': 256},
        },
        required: ['sceneRevision', 'viewportId'],
      ),
      outputSchema: _anchorOutput,
    ),
  ];

  /// Unregister from AgentRegistry first. This provider does not own the session.
  void dispose() {
    _disposed = true;
    _hits.clear();
  }

  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    if (_disposed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'XR provider is disposed.',
      );
    }
    final binding = view();
    void checkCurrent() {
      context.checkCancelled();
      if (_disposed) {
        throw const XrException('disposed', 'XR provider is disposed.');
      }
      if (!binding.sameView(view())) {
        throw const XrException(
          'staleRevision',
          'The host view changed during this call.',
        );
      }
    }

    try {
      context.checkCancelled();
      if (tool == 'screen_raycast' && raycast != null) {
        final result = await raycast!(
          (arguments['x'] as num).toDouble(),
          (arguments['y'] as num).toDouble(),
        );
        checkCurrent();
        if (binding.presentedFrameId != result.frameId ||
            binding.presentedSceneRevision != binding.sceneRevision ||
            binding.calibration?.epoch != result.epoch ||
            binding.calibration?.timestamp != result.frameTimestamp ||
            view().presentedFrameId != result.frameId) {
          throw const XrException(
            'staleFrame',
            'The host presentation changed.',
          );
        }
        final hits = <Map<String, Object?>>[];
        for (final hit in result.hits) {
          final token = '${commands.session.id}:${_nextHit++}';
          _hits[token] = (result, hit, binding);
          while (_hits.length > 32) {
            _hits.remove(_hits.keys.first);
          }
          hits.add({...hit.toJson(), 'hitToken': token});
        }
        return AgentResult(
          AgentStatus.ok,
          revision: revision,
          data: {
            'hits': hits,
            'omittedHits': result.omittedHits,
            'view': binding.toJson(),
            'sessionId': commands.session.id,
            'sessionRevision': result.sessionRevision,
            'originEpoch': result.originEpoch,
            'presentedFrameId': result.frameId,
            'frameTimestamp': result.frameTimestamp,
            'sensorTimestamp': result.sensorTimestamp,
            'coverage': 'native-plane-geometry-estimate',
          },
        );
      }
      if (tool == 'inspect') {
        final snapshot = await commands.session.snapshot();
        checkCurrent();
        final actions = <String>[];
        if (allowPlacement) {
          try {
            _requireTracking(snapshot);
            actions.add('place_anchor');
            if (raycast != null) actions.add('place_hit');
          } on XrException {
            /* Tracking state explains why placement is absent. */
          }
          if (commands.canUndo) actions.add('undo_placement');
        }
        return AgentResult(
          AgentStatus.ok,
          revision: revision,
          data: {
            'session': _snapshot(snapshot, arguments),
            'view': binding.toJson(),
            'capabilities': capabilities,
            'availableActions': actions,
          },
        );
      }
      if (tool != 'place_anchor' &&
          tool != 'undo_placement' &&
          tool != 'place_hit') {
        return AgentResult(
          AgentStatus.unsupported,
          message: 'Unsupported XR tool.',
        );
      }
      if (!allowPlacement) {
        return AgentResult(
          AgentStatus.denied,
          message: 'The host disabled XR placement.',
        );
      }
      if (arguments['sceneRevision'] != binding.sceneRevision ||
          arguments['viewportId'] != binding.viewportId) {
        return AgentResult(
          AgentStatus.stale,
          message: 'The target view changed.',
        );
      }
      final String anchor;
      if (tool == 'place_hit') {
        final saved = _hits[arguments['hitToken']];
        if (saved == null ||
            !saved.$3.sameView(binding) ||
            saved.$1.epoch != binding.calibration?.epoch) {
          throw const XrException('staleFrame', 'Raycast a fresh native hit.');
        }
        anchor = await commands.place(
          pose: saved.$2.pose,
          expectedRevision: context.expectedRevision!,
          expectedSessionRevision: saved.$1.sessionRevision,
          expectedFrameTimestamp: saved.$1.frameTimestamp,
          expectedPresenterId: saved.$1.presenterId,
          expectedPresentationEpoch: saved.$1.epoch,
          checkCurrent: () {
            checkCurrent();
            if (view().calibration?.epoch != saved.$1.epoch) {
              throw const XrException(
                'staleFrame',
                'The camera viewport changed.',
              );
            }
          },
        );
        _hits.clear();
      } else if (tool == 'place_anchor') {
        anchor = await commands.place(
          pose: XrPose((arguments['transform'] as List).cast<num>()),
          expectedRevision: context.expectedRevision!,
          expectedSessionRevision: arguments['sessionRevision'] as int,
          expectedFrameTimestamp: (arguments['frameTimestamp'] as num)
              .toDouble(),
          checkCurrent: checkCurrent,
        );
      } else {
        anchor = await commands.undo(
          expectedRevision: context.expectedRevision!,
          checkCurrent: checkCurrent,
        );
      }
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        affectedIds: [anchor],
        data: {'anchorId': anchor, 'sessionId': commands.session.id},
      );
    } on XrException catch (error) {
      if (error.code == 'empty') {
        return AgentResult(
          AgentStatus.empty,
          revision: revision,
          message: error.message,
          data: {'sessionId': commands.session.id},
        );
      }
      final status = switch (error.code) {
        'staleRevision' || 'staleFrame' || 'unknownAnchor' => AgentStatus.stale,
        'permissionDenied' || 'permissionRestricted' => AgentStatus.denied,
        'unsupportedFeature' ||
        'unsupportedHardware' => AgentStatus.unsupported,
        'cancelled' => AgentStatus.cancelled,
        'empty' => AgentStatus.empty,
        'nativeFailure' || 'sessionFailed' => AgentStatus.failed,
        _ => AgentStatus.unavailable,
      };
      return AgentResult(status, message: error.message);
    } on ArgumentError {
      return AgentResult(
        AgentStatus.invalid,
        message: 'The placement transform must be rigid.',
      );
    }
  }

  Map<String, Object?> _snapshot(XrSnapshot s, Map<String, Object?> args) {
    final frame = s.frame;
    final limit = args['limit'] as int? ?? 16;
    final ao = args['anchorOffset'] as int? ?? 0;
    final po = args['planeOffset'] as int? ?? 0;
    return {
      'id': commands.session.id,
      'state': s.state.name,
      'revision': s.revision,
      'nativeTimestamp': s.nativeTimestamp,
      'failure': s.failure == null
          ? null
          : {'code': s.failure!.code, 'message': s.failure!.message},
      'frame': frame == null
          ? null
          : {
              'timestamp': frame.timestamp,
              'ageSeconds': frame.ageAt(s.nativeTimestamp),
              'tracking': frame.tracking.name,
              'trackingReason': frame.trackingReason,
              'cameraTransform': frame.cameraPose.matrix,
              'intrinsics': frame.intrinsics,
              'imageWidth': frame.imageWidth,
              'imageHeight': frame.imageHeight,
              'cameraPoseOrientation': 'image-sensor',
              'calibratedViewportProjection': null,
              'anchors': frame.anchors
                  .skip(ao)
                  .take(limit)
                  .map(
                    (a) => {
                      'runtimeId': a.id,
                      'sourceId': null,
                      'transform': a.pose.matrix,
                      'identityScope': commands.session.id,
                    },
                  )
                  .toList(),
              'planes': frame.planes
                  .skip(po)
                  .take(limit)
                  .map(
                    (p) => {
                      'runtimeId': p.id,
                      'sourceId': null,
                      'transform': p.pose.matrix,
                      'center': p.center,
                      'extent': p.extent,
                      'alignment': p.alignment,
                      'provenance':
                          '${deviceCapabilities.platform}-plane-estimate',
                      'pixelVisibility': 'unknown',
                    },
                  )
                  .toList(),
              'nextAnchorOffset': ao + limit < frame.anchors.length
                  ? ao + limit
                  : null,
              'nextPlaneOffset': po + limit < frame.planes.length
                  ? po + limit
                  : null,
              'omittedNativePlanes': frame.omittedPlanes,
              'light': frame.light == null
                  ? null
                  : {
                      'ambientIntensity': frame.light!.ambientIntensity,
                      'intensityUnit': frame.light!.intensityUnit,
                      'colorCorrectionGamma': frame.light!.colorCorrection,
                      'colorTemperatureKelvin': frame.light!.colorTemperature,
                      'provenance':
                          '${deviceCapabilities.platform}-ambient-estimate',
                    },
            },
    };
  }
}

const _offset = {'type': 'integer', 'minimum': 0};
const _strings = {
  'type': 'array',
  'maxItems': 3,
  'items': {'type': 'string'},
};
final _anchorOutput = _object(
  {
    'anchorId': {'type': 'string'},
    'sessionId': {'type': 'string'},
  },
  required: ['sessionId'],
);
Map<String, Object?> _object(
  Map<String, Object?> fields, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': fields,
  'required': required,
  'additionalProperties': false,
};
