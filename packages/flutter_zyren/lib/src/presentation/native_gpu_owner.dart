import 'dart:typed_data';
import 'package:zyren/rendering.dart';
import 'package:zyren/zyren.dart'
    show ResourceScope, ShaderCompiler, GraphCompiler, MaterialCompiler;
import 'package:zyren_native/zyren_native.dart';

/// Shared ownership for channel-backed renderers. Each host serializes GPU
/// commands with scene rendering on its existing native queue.
mixin NativeGpuOwner implements MaterialBackend, GpuDiagnosticsBackend {
  bool get gpuOwnerClosed;
  Future<Map> gpuRequest(Map<String, Object> arguments);
  NativeGpuContext? _gpu;
  Set<int> _gpuSampleCounts = const {1};
  Set<int> get gpuSampleCounts => _gpuSampleCounts;
  Future<void> loadGpuCapabilities() async {
    _gpuSampleCounts = (await _context.deviceInfo()).sampleCounts;
  }

  NativeGpuContext get _context {
    if (gpuOwnerClosed) throw StateError('Native view has closed.');
    return _gpu ??= NativeGpuContext((operation, bytes, capacity) async {
      final response = await gpuRequest({
        'operation': operation,
        'data': bytes,
        'capacity': capacity,
      });
      final status = response['status'] as int;
      return status == 0
          ? NativeGpuReply.success(response['data'] as Uint8List)
          : NativeGpuReply.failure(status, response['error'] as String);
    });
  }

  @override
  Future<GpuInspection> inspectGpu({int allocationLimit = 128}) =>
      _context.inspectGpu(allocationLimit: allocationLimit);

  @override
  ResourceScope createResourceScope({String label = ''}) =>
      _context.createResourceScope(label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      _context.createShaderCompiler(label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      _context.createGraphCompiler(label: label);
  Future<void> closeGpuScopes() async {
    await _gpu?.close();
  }

  @override
  MaterialCompiler createMaterialCompiler({String label = ''}) =>
      _context.createMaterialCompiler(label: label);
  ScenePacketEncoder createGpuSceneEncoder({required int viewId}) =>
      _context.createSceneEncoder(viewId: viewId);
}
