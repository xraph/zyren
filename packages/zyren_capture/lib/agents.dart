import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_capture.dart';

Map<String, Object?> _input(
  Map<String, Object?> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
const _id = {'type': 'string', 'minLength': 1, 'maxLength': 64};
const _output = {'type': 'object'};

/// The host chooses the scene and output parent. Agents cannot supply file paths.
final class CaptureAgentProvider extends AgentProvider {
  final CaptureManager manager;
  final int maxDimension, maxFrames;
  final _ownedJobs = <String>{};
  Registration register(AgentRegistry registry) {
    final registration = registry.register(this);
    return Registration(() {
      registration.dispose();
      for (final job in manager.jobs) {
        if (_ownedJobs.contains(job.id)) job.cancel();
      }
      _ownedJobs.clear();
    });
  }

  @override
  final String instanceId;
  CaptureAgentProvider({
    required this.manager,
    required this.instanceId,
    this.maxDimension = 1024,
    this.maxFrames = 120,
  }) {
    if (maxDimension < 1 ||
        maxDimension > 8192 ||
        maxFrames < 1 ||
        maxFrames > 720) {
      throw ArgumentError('Invalid agent capture limits.');
    }
  }
  @override
  String get id => 'zyren_capture';
  @override
  String get version => '0.1.0';
  @override
  int get revision => manager.revision + manager.scene.revision;
  @override
  Map<String, Object?> get capabilities => {
    'sceneId': manager.sceneId,
    'documentId': manager.documentId,
    'maxDimension': maxDimension,
    'maxFrames': maxFrames,
    'formats': ['png'],
    'video': 'optional separate VideoAgentProvider',
    'tiledCapture': '32 megapixels maximum; no screen-space effects',
    'depth': 'unsupported',
    'objectId': 'unsupported',
    'extent': 'scene pixels; isolated camera; no Flutter overlays',
    'presentedViewportCorrelation': 'unavailable',
    'cancellation': 'between native frames, tiles and file writes',
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'jobs',
      description:
          'Inspect bounded capture history, progress and completed artifacts.',
      inputSchema: _input({}),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'start',
      description:
          'Start a bounded native still or turntable job with a host-owned output directory.',
      inputSchema: _input(
        {
          'jobId': _id,
          'width': {'type': 'integer', 'minimum': 1, 'maximum': maxDimension},
          'height': {'type': 'integer', 'minimum': 1, 'maximum': maxDimension},
          'frames': {'type': 'integer', 'minimum': 1, 'maximum': maxFrames},
          'tileDimension': {'type': 'integer', 'minimum': 16, 'maximum': 2048},
          'fps': {'type': 'integer', 'minimum': 1, 'maximum': 240},
          'radius': {'type': 'number', 'minimum': .001, 'maximum': 1e9},
          'center': {
            'type': 'array',
            'minItems': 3,
            'maxItems': 3,
            'items': {'type': 'number', 'minimum': -1e12, 'maximum': 1e12},
          },
        },
        ['jobId', 'width', 'height'],
      ),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'capture.write'},
    ),
    AgentTool(
      name: 'cancel',
      description: 'Cancel a queued/running job and wait for scoped cleanup.',
      inputSchema: _input({'jobId': _id}, ['jobId']),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'capture.write'},
    ),
  ];
  Map<String, Object?> _job(CaptureJob job) => {
    'id': job.id,
    'state': job.state.name,
    'completedFrames': job.completedFrames,
    'totalFrames': job.plan.frameCount,
    'error': job.error == null
        ? null
        : 'Capture failed; inspect host diagnostics.',
    'artifact': job.artifact == null
        ? null
        : {
            'directory': job.artifact!.directory,
            'manifest': job.artifact!.manifest,
            'frames': job.artifact!.frames,
          },
  };
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (manager.isClosed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Capture manager has closed.',
      );
    }
    if (tool == 'jobs') {
      return AgentResult(
        manager.jobs.isEmpty ? AgentStatus.empty : AgentStatus.ok,
        revision: revision,
        data: {'jobs': manager.jobs.map(_job).toList()},
      );
    }
    final jobId = arguments['jobId'] as String;
    if (tool == 'start') {
      try {
        final coordinates = arguments['center'] as List?;
        final job = manager.start(
          id: jobId,
          plan: CapturePlan(
            size: PhysicalSize(
              arguments['width'] as int,
              arguments['height'] as int,
            ),
            frameCount: arguments['frames'] as int? ?? 1,
            tileDimension: arguments['tileDimension'] as int?,
            framesPerSecond: arguments['fps'] as int? ?? 30,
            radius: (arguments['radius'] as num?)?.toDouble() ?? 5,
            center: coordinates == null
                ? Vec3.zero
                : Vec3.array(
                    coordinates.cast<num>().map((v) => v.toDouble()).toList(),
                  ),
          ),
        );
        _ownedJobs.add(jobId);
        return AgentResult(
          AgentStatus.ok,
          revision: revision,
          affectedIds: [jobId],
          data: {'job': _job(job)},
        );
      } on ArgumentError {
        return AgentResult(
          AgentStatus.invalid,
          message: 'Invalid capture parameters or duplicate job ID.',
        );
      } on StateError {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Capture admission is unavailable.',
        );
      }
    }
    if (tool == 'cancel') {
      final matches = manager.jobs.where((j) => j.id == jobId);
      if (matches.isEmpty) {
        return AgentResult(AgentStatus.stale, message: 'Unknown capture job.');
      }
      final job = matches.first;
      manager.cancel(jobId);
      try {
        await job.done;
      } catch (_) {}
      return AgentResult(
        job.state == CaptureState.failed ? AgentStatus.failed : AgentStatus.ok,
        revision: revision,
        affectedIds: [jobId],
        data: {'job': _job(job)},
      );
    }
    return AgentResult(AgentStatus.unsupported);
  }
}
