/// Read-only GPU tool adapter for an attached scene inspector.
library;

import 'zyren_devtools.dart';

final class GpuInspectionTools {
  final SceneDevtoolsPlugin inspector;
  GpuInspectionTools(this.inspector);

  List<Map<String, Object?>> get tools => [
    {
      'name': 'zyren_gpu_inspect',
      'description':
          'Inspect the attached device allocation counter, last scene GPU submission and bounded registry payload metadata.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'allocationLimit': {'type': 'integer', 'minimum': 1, 'maximum': 256},
        },
        'additionalProperties': false,
      },
    },
  ];

  Future<Map<String, Object?>> call(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    if (name != 'zyren_gpu_inspect') throw ArgumentError.value(name, 'name');
    if (arguments.keys.any((key) => key != 'allocationLimit')) {
      throw ArgumentError('Unknown inspection argument.');
    }
    final limit = arguments['allocationLimit'] ?? 128;
    if (limit is! int) {
      throw ArgumentError('allocationLimit must be an integer.');
    }
    final inspection = await inspector.inspectGpu(allocationLimit: limit);
    return inspection?.toJson() ??
        {'available': false, 'reason': 'backendUnsupported'};
  }
}
