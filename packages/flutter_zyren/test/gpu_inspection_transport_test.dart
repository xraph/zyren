import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/rendering.dart';
import 'package:flutter_zyren/src/presentation/native_gpu_owner.dart';

class _Owner with NativeGpuOwner {
  @override
  bool gpuOwnerClosed = false;
  int requests = 0;
  @override
  Future<Map> gpuRequest(Map<String, Object> arguments) async {
    requests++;
    expect(arguments['operation'], 'graph');
    final request =
        jsonDecode(utf8.decode(arguments['data'] as Uint8List)) as Map;
    expect(request['command'], {
      'operation': 'inspectGpu',
      'allocation_limit': 2,
    });
    return {
      'status': 0,
      'data': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'request': request['request'],
            'result': {
              'lastSubmissionGpuTimeNs': null,
              'submittedFrames': 0,
              'gpuTimeSource': 'unavailable',
              'deviceAllocatedBytes': null,
              'deviceAllocationSource': 'unavailable',
              'registryPayloadBytes': 0,
              'totalAllocations': 0,
              'allocations': [],
              'residentBytes': null,
            },
          }),
        ),
      ),
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'host diagnostics use the existing native queue and reject after close',
    () async {
      final owner = _Owner();
      expect(owner, isA<GpuDiagnosticsBackend>());
      final result = await owner.inspectGpu(allocationLimit: 2);
      expect(result.deviceAllocatedBytes, isNull);
      expect(result.residentBytes, isNull);
      expect(result.allocations, isEmpty);
      expect(owner.requests, 1);
      await owner.closeGpuScopes();
      owner.gpuOwnerClosed = true;
      expect(() => owner.inspectGpu(allocationLimit: 2), throwsStateError);
      expect(owner.requests, 1);
    },
  );
}
