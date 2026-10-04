import 'dart:io';
// The Dart VM test runner supports mirrors; Flutter's patched SDK omits it.
// Run this native-only fixture with fvm dart test, not flutter test.
// ignore: uri_does_not_exist
import 'dart:mirrors' as vm;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_native/src/worker_session.dart';

// VM-only injection avoids adding a failure switch to the public backend API.
Object? privateField(Object value, String name) {
  // ignore: undefined_function
  final dynamic mirror = vm.reflect(value);
  // ignore: undefined_prefixed_name
  final symbol = vm.MirrorSystem.getSymbol(name, mirror.type.owner);
  return mirror.getField(symbol).reflectee;
}

Future<Object> failed(Future<void> operation) async {
  try {
    await operation;
  } catch (error) {
    return error;
  }
  throw StateError('Expected the injected cleanup failure.');
}

final class RejectClose implements SceneCaptureView {
  final SceneCaptureView view;
  final error = StateError('injected capture-close failure');
  final stack = StackTrace.fromString('injected capture-close stack');
  var closeCount = 0;
  RejectClose(this.view);
  @override
  Future<void> close() async {
    closeCount++;
    Error.throwWithStackTrace(error, stack);
  }

  @override
  Future<void> clear() => view.clear();
  @override
  void configureSceneUploadBudget(int bytes) =>
      view.configureSceneUploadBudget(bytes);
  @override
  Future<SceneCaptureReceipt> capture(
    FrameSubmission frame,
    GpuResource<Texture> target,
  ) => view.capture(frame, target);
}

final class ProbeBackend implements GraphBackend, CaptureBackend {
  final NativeBackend native;
  late RejectClose capture;
  late ResourceScope owner;
  ProbeBackend(this.native);
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      owner = native.createResourceScope(label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      native.createShaderCompiler(label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      native.createGraphCompiler(label: label);
  @override
  Future<SceneCaptureView> createCaptureView() async =>
      capture = RejectClose(await native.createCaptureView());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'GPU services attempt every owner after capture close and release reject',
    () async {
      final operations = <int>[];
      final gpu = NativeGpuServices.withTransport((
        kind,
        packet,
        capacity,
      ) async {
        expect(kind, NativeGpuCommand.resource);
        final request = ByteData.sublistView(packet);
        final opcode = request.getUint32(4, Endian.little);
        operations.add(opcode);
        if (opcode == 101) {
          return NativeGpuReply.failure(6, 'injected capture-close failure');
        }
        if (opcode == 6) {
          return NativeGpuReply.failure(6, 'injected resource-release failure');
        }
        final reply = ByteData(capacity)
          ..setUint32(0, 2, Endian.little)
          ..setUint64(8, request.getUint64(8, Endian.little), Endian.little)
          ..setUint64(16, capacity - 24, Endian.little);
        if (capacity > 24) reply.setUint64(24, 1, Endian.little);
        return NativeGpuReply.success(reply.buffer.asUint8List());
      });
      final capture = await gpu.createCaptureView();
      final resources = gpu.createResourceScope();
      await resources.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      final shaders = gpu.createShaderCompiler();
      final graphs = gpu.createGraphCompiler();
      final materials = gpu.createMaterialCompiler();
      final closing = gpu.close();
      final error = await failed(closing);
      expect(resources.isClosed, isTrue);
      expect(shaders.isClosed, isTrue);
      expect(graphs.isClosed, isTrue);
      expect(materials.isClosed, isTrue);
      expect(operations, containsAllInOrder([101, 6]));
      expect(error, isA<ScopeCleanupException>());
      expect(
        (error as ScopeCleanupException).errors.first,
        same(await failed(capture.close())),
      );
      expect(error.errors.length, 2);
      expect(gpu.close(), same(closing));
    },
  );

  test(
    'aborted native worker still releases backend view and all owners',
    () async {
      final backend = await NativeBackend.create();
      final capture = await backend.createCaptureView();
      final resources = backend.createResourceScope();
      await resources.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      final shaders = backend.createShaderCompiler();
      final graphs = backend.createGraphCompiler();
      final materials = backend.createMaterialCompiler();
      final renderer = privateField(backend, '_renderer')!;
      final worker = privateField(renderer, '_worker') as WorkerSession;
      worker.abort();
      final closing = backend.close();
      final error = await failed(closing);
      expect(error, same(await failed(capture.close())));
      expect(resources.isClosed, isTrue);
      expect(shaders.isClosed, isTrue);
      expect(graphs.isClosed, isTrue);
      expect(materials.isClosed, isTrue);
      expect(privateField(renderer, '_owners'), 0);
      expect(privateField(renderer, '_closed'), isTrue);
      expect(backend.close(), same(closing));
      final recovered = await NativeBackend.create();
      try {
        final frame = await recovered.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(8, 8),
          ),
        );
        expect(frame.stats.admission!.candidateReady, isTrue);
      } finally {
        await recovered.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'collection closes maps and retirement tickets after capture close rejects',
    () async {
      final native = await NativeBackend.create();
      final backend = ProbeBackend(native);
      final probes = await ReflectionProbes.create(backend);
      final borrower = native.createResourceScope();
      final d = ReflectionProbeDescriptor(
        id: 0,
        position: Vec3.zero,
        bounds: Bounds3(-Vec3.one, Vec3.one),
        faceSize: 16,
        quality: const EnvironmentQuality(
          specularWidth: 16,
          diffuseWidth: 16,
          brdfSize: 16,
          samples: 64,
        ),
      );
      try {
        await probes.update(d, scene: Scene(), contentRevision: 1);
        while (probes.pending) {
          await probes.advance();
        }
        final old = await probes.environment(0)!.map.retain(borrower);
        await probes.update(d, scene: Scene(), contentRevision: 2);
        while (probes.pending) {
          await probes.advance();
        }
        final current = probes.environment(0)!.map;
        expect(probes.retainedGenerations, 1);
        await probes.update(d, scene: Scene(), contentRevision: 3);
        await probes.advance();
        expect(probes.pending, isTrue);
        Object? error;
        StackTrace? stack;
        try {
          await probes.close();
        } catch (e, s) {
          error = e;
          stack = s;
        }
        expect(stack.toString(), contains('injected capture-close stack'));
        expect(error, isA<ScopeCleanupException>());
        expect(
          (error as ScopeCleanupException).errors.first,
          same(backend.capture.error),
        );
        expect(backend.owner.isClosed, isTrue);
        expect(current.isClosed, isTrue);
        expect(probes.retainedGenerations, 0);
        expect(probes.storageBytes, 0);
        // Forced ticket disposal preserves a genuine external map owner.
        expect(old.isClosed, isFalse);
        await borrower.readTexture(await borrower.retain(old.specular));
        await borrower.close();
        await backend.capture.view.close();
        expect((await native.resourceStats()).liveAllocations, 0);
        expect(backend.capture.closeCount, 1);
      } finally {
        await borrower.close();
        await backend.capture.view.close();
        await native.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
