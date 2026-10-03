/// Shared Agents tools for host-selected game builds.
library;

import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'export.dart';
import 'compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

final class GameStudioAgentProvider extends AgentProvider {
  final GameBuildCommands commands;
  @override
  final String instanceId;
  int? _registrationId;
  bool _retired = false;
  GameStudioAgentProvider({required this.commands, required this.instanceId});
  @override
  String get id => 'zyren.game-build';
  @override
  String get version => '0.1.0';
  @override
  int get revision => commands.stateRevision;
  Registration attach(AgentRegistry registry) {
    if (_registrationId != null || _retired) {
      throw StateError('Build provider already attached or retired.');
    }
    final lease = registry.register(this);
    for (var offset = 0; ; offset += 32) {
      final page = registry.discover(offset: offset);
      for (final entry in page['providers'] as List) {
        if (entry['providerId'] == id && entry['instanceId'] == instanceId) {
          _registrationId = entry['registrationId'] as int;
        }
      }
      if (page['nextOffset'] == null) break;
    }
    return Registration(() {
      _retired = true;
      lease.dispose();
      unawaited(commands.close());
    });
  }

  @override
  Map<String, Object?> get capabilities => {
    'output': 'host-selected',
    'compilerVersion': GameProjectCompiler.version,
    'componentCollaboration': 'leave-session-required',
  };
  static const _id = {'type': 'string', 'minLength': 1, 'maxLength': 128};
  static const _revision = {'type': 'integer', 'minimum': 0};
  static const _object = {'type': 'object'};
  @override
  List<AgentTool> get tools => [
    for (final name in ['inspect', 'jobs'])
      AgentTool(
        name: name,
        description:
            'Inspect game build validation, pins, capabilities and host output.',
        inputSchema: const {
          'type': 'object',
          'properties': {},
          'additionalProperties': false,
        },
        outputSchema: _object,
      ),
    AgentTool(
      name: 'build',
      description: 'Start a build of the current reviewed authored revision.',
      readOnly: false,
      requiredScopes: {'game.build'},
      inputSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'documentRevision': _revision,
          'registrationId': _revision,
        },
        'required': ['documentRevision', 'registrationId'],
      },
      outputSchema: _object,
    ),
    AgentTool(
      name: 'cancel',
      description: 'Cancel an owned game build job.',
      readOnly: false,
      requiredScopes: {'game.build'},
      inputSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {'jobId': _id, 'registrationId': _revision},
        'required': ['jobId', 'registrationId'],
      },
      outputSchema: _object,
    ),
  ];
  Map<String, Object?> _job(PipelineBuildJob job) => {
    'jobId': job.id,
    'state': job.state.name,
    if (job.errorCode != null) 'errorCode': job.errorCode,
    if (job.result != null) 'bundleVersion': job.result!.bundle.version,
  };
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (_retired || _registrationId == null || commands.isClosed) {
      return AgentResult(AgentStatus.unavailable);
    }
    if (tool == 'inspect') {
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'documentRevision': commands.revision(),
          'registrationId': _registrationId,
          'output': commands.currentOutputLabel,
          'profile': commands.profile().toJson(),
          'validation': commands.validationDiagnostics,
          'assetPins': [
            for (final asset
                in commands.documents().expand((doc) => doc.assets).take(16))
              asset.toJson(),
          ],
          'assetCount': commands.documents().fold<int>(
            0,
            (count, doc) => count + doc.assets.length,
          ),
          'modelPins': commands.models().map(
            (key, value) => MapEntry(key, value.toJson()),
          ),
          'compilerVersion': GameProjectCompiler.version,
          'capabilities': commands.profile().capabilities.toList()..sort(),
        },
      );
    }
    if (tool == 'jobs') {
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {'jobs': commands.jobs.map(_job).toList()},
      );
    }
    if (arguments['registrationId'] != _registrationId) {
      return AgentResult(AgentStatus.stale, revision: revision);
    }
    if (tool == 'cancel') {
      final changed = commands.cancel(arguments['jobId'] as String);
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {'changed': changed},
      );
    }
    if (tool == 'build') {
      final result = commands.startBuild(
        expectedRevision: arguments['documentRevision'] as int,
        requestId: 'agent-${context.idempotencyKey!}',
      );
      return switch (result) {
        StartedBuildResult() => AgentResult(
          AgentStatus.ok,
          revision: revision,
          data: {
            'job': _job(result.job),
            'documentRevision': result.documentRevision,
          },
        ),
        InvalidBuildResult() => AgentResult(
          AgentStatus.invalid,
          revision: revision,
          data: {'diagnostics': result.diagnostics},
        ),
        StaleBuildResult() => AgentResult(
          AgentStatus.stale,
          revision: revision,
        ),
        DeniedBuildResult() => AgentResult(
          AgentStatus.denied,
          revision: revision,
        ),
        UnavailableBuildResult() => AgentResult(
          AgentStatus.unavailable,
          revision: revision,
        ),
      };
    }
    return AgentResult(AgentStatus.unsupported);
  }
}
