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
    'xrCameraPresentation': false,
    'screenToXrRaycast': 'unsupported',
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
  @override
  final String instanceId;
  bool _disposed = false;
  XrAgentProvider({
    required this.instanceId,
    required this.commands,
    required this.deviceCapabilities,
    required this.view,
    this.allowPlacement = false,
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
    'screenRaycast': 'unsupported',
    'pixelVisibility': 'unknown',
  };

  @override
  List<AgentTool> get tools => [
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
      if (tool == 'inspect') {
        final snapshot = await commands.session.snapshot();
        checkCurrent();
        final actions = <String>[];
        if (allowPlacement) {
          try {
            _requireTracking(snapshot);
            actions.add('place_anchor');
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
      if (tool != 'place_anchor' && tool != 'undo_placement') {
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
      if (tool == 'place_anchor') {
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
                      'provenance': 'arkit-plane-estimate',
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
                      'colorTemperatureKelvin': frame.light!.colorTemperature,
                      'provenance': 'arkit-ambient-estimate',
                    },
            },
    };
  }
}

const _offset = {'type': 'integer', 'minimum': 0};
const _strings = {
  'type': 'array',
  'maxItems': 2,
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
