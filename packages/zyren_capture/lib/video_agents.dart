import 'dart:async';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'video.dart';
import 'zyren_capture.dart';

/// Host-selected encoder and output directory. Tools accept completed capture
/// IDs, never filesystem paths, executable names or arbitrary encoder flags.
final class VideoAgentProvider extends AgentProvider {
  final CaptureManager captures;
  final Directory outputParent;
  final String executable;
  final int maxJobs;
  @override
  final String instanceId;
  final _jobs = <String, _Export>{};
  int _revision = 0;
  bool _detached = false;
  VideoAgentProvider({
    required this.captures,
    required this.outputParent,
    required this.instanceId,
    this.executable = 'ffmpeg',
    this.maxJobs = 16,
  }) {
    if (maxJobs < 1 || maxJobs > 32) {
      throw ArgumentError('Invalid export history budget.');
    }
  }
  @override
  String get id => 'zyren_capture.video';
  @override
  String get version => '0.1.0';
  @override
  int get revision => _revision + captures.revision;
  @override
  Map<String, Object?> get capabilities => {
    'codec': 'h264',
    'container': 'mp4',
    'alpha': 'discarded',
    'audio': 'none',
    'maxJobs': maxJobs,
    'availability': 'requires host-installed FFmpeg/libx264',
  };
  Registration register(AgentRegistry registry) {
    if (_detached) throw StateError('Video provider has detached.');
    final registration = registry.register(this);
    return Registration(() {
      registration.dispose();
      _detached = true;
      for (final job in _jobs.values) {
        job.export.cancel();
      }
    });
  }

  Map<String, Object?> _input(
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  static const _id = {'type': 'string', 'minLength': 1, 'maxLength': 64};
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'jobs',
      description: 'Inspect bounded video exports and completed artifacts.',
      inputSchema: _input({}, []),
      outputSchema: const {'type': 'object'},
    ),
    AgentTool(
      name: 'start',
      description: 'Encode a completed capture as an opaque fixed-rate MP4.',
      inputSchema: _input(
        {
          'jobId': _id,
          'captureId': _id,
          'fps': {'type': 'integer', 'minimum': 1, 'maximum': 240},
        },
        ['jobId', 'captureId', 'fps'],
      ),
      outputSchema: const {'type': 'object'},
      readOnly: false,
      requiredScopes: {'capture.video'},
    ),
    for (final tool in ['cancel', 'forget'])
      AgentTool(
        name: tool,
        description: tool == 'cancel'
            ? 'Cancel an export and wait for private output cleanup.'
            : 'Drop completed export history; retain output files.',
        inputSchema: _input({'jobId': _id}, ['jobId']),
        outputSchema: const {'type': 'object'},
        readOnly: false,
        requiredScopes: {'capture.video'},
      ),
  ];
  Map<String, Object?> _state(String id, _Export value) => {
    'id': id,
    'state': value.state.name,
    'completedFrames': value.export.completedFrames,
    'error': value.error,
    'artifact': value.artifact == null
        ? null
        : {'path': value.artifact!.path, 'manifest': value.artifact!.manifest},
  };
  Future<void> _watch(_Export job) async {
    try {
      job.artifact = await job.export.done;
      job.state = CaptureState.completed;
    } on CaptureCancelled {
      job.state = CaptureState.cancelled;
    } catch (_) {
      job.state = CaptureState.failed;
      job.error = 'Encoder failed; inspect host diagnostics.';
    }
    _revision++;
  }

  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (_detached) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Video provider has detached.',
      );
    }
    if (tool == 'jobs') {
      return AgentResult(
        _jobs.isEmpty ? AgentStatus.empty : AgentStatus.ok,
        revision: revision,
        data: {
          'jobs': [
            for (final entry in _jobs.entries) _state(entry.key, entry.value),
          ],
        },
      );
    }
    final jobId = arguments['jobId'] as String;
    if (tool == 'start') {
      if (_jobs.containsKey(jobId)) {
        return AgentResult(
          AgentStatus.invalid,
          message: 'Duplicate export ID.',
        );
      }
      if (_jobs.length >= maxJobs ||
          _jobs.values.any((job) => !job.export.isFinished)) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Export admission limit reached.',
        );
      }
      final source = captures.jobs
          .where((job) => job.id == arguments['captureId'])
          .firstOrNull;
      if (source?.artifact == null) {
        return AgentResult(
          AgentStatus.stale,
          message: 'Capture has no completed image sequence.',
        );
      }
      final job = _Export(
        VideoExport(
          source: source!.artifact!,
          outputParent: outputParent,
          executable: executable,
          framesPerSecond: arguments['fps'] as int,
          onProgress: (_) {
            _revision++;
          },
        ),
      );
      _jobs[jobId] = job;
      _revision++;
      job.done = _watch(job);
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        affectedIds: [jobId],
        data: {'job': _state(jobId, job)},
      );
    }
    final job = _jobs[jobId];
    if (job == null) {
      return AgentResult(AgentStatus.stale, message: 'Unknown export ID.');
    }
    if (tool == 'cancel') {
      job.export.cancel();
      await job.done;
    } else if (tool == 'forget') {
      if (!job.export.isFinished) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Export is still running.',
        );
      }
      _jobs.remove(jobId);
    } else {
      return AgentResult(AgentStatus.unsupported);
    }
    _revision++;
    return AgentResult(
      job.state == CaptureState.failed ? AgentStatus.failed : AgentStatus.ok,
      revision: revision,
      affectedIds: [jobId],
      data: {'job': _state(jobId, job)},
    );
  }
}

final class _Export {
  final VideoExport export;
  CaptureState state = CaptureState.running;
  VideoArtifact? artifact;
  String? error;
  late Future<void> done;
  _Export(this.export);
}
