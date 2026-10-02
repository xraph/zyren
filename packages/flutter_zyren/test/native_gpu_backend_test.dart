@TestOn('mac-os')
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:flutter_zyren/src/presentation/native_android_presenter.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';

import 'support/texture_formats.dart';
import 'support/device_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final android in [false, true]) {
    final channel = MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    );
    Future<RenderBackend> create() async => android
        ? NativeAndroidBackend.create(runtimeToken: 10)
        : NativeMetalBackend.create(runtimeToken: 10);
    group(android ? 'Vulkan services' : 'Metal services', () {
      setUp(() {
        debugDefaultTargetPlatformOverride = android
            ? TargetPlatform.android
            : TargetPlatform.macOS;
      });
      tearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      for (final (releaseFails, closeFails) in [
        (false, false),
        (true, false),
        (true, true),
      ]) {
        test(
          'close drains resources, release failure $releaseFails, close failure $closeFails',
          () async {
            final gate = Completer<Object?>();
            final events = <String>[];
            messenger.setMockMethodCallHandler(channel, (call) async {
              switch (call.method) {
                case 'connect':
                  return null;
                case 'create':
                  return {'session': 7, 'adapter': 'native test'};
                case 'gpuCommand':
                  final args = call.arguments as Map;
                  expect(args['session'], 7);
                  if (args['kind'] == 'graph') return deviceInfoReply(args);
                  expect(args['kind'], 'resource');
                  final packet = ByteData.sublistView(
                    args['bytes'] as Uint8List,
                  );
                  final opcode = packet.getUint32(4, Endian.little);
                  if (opcode == 11) return textureFormatsReply(call, mask: 31);
                  events.add('resource.$opcode');
                  if (opcode == 1) return gate.future;
                  if (releaseFails) {
                    return {'status': 2, 'message': 'release failed'};
                  }
                  final bytes = ByteData(24)
                    ..setUint32(0, 2, Endian.little)
                    ..setUint64(
                      8,
                      packet.getUint64(8, Endian.little),
                      Endian.little,
                    );
                  return {'status': 0, 'bytes': bytes.buffer.asUint8List()};
                case 'close':
                  events.add('close');
                  if (closeFails) throw PlatformException(code: 'closeFailed');
                  return null;
                default:
                  throw StateError(call.method);
              }
            });
            final backend = await create();
            expect(backend, isA<GraphBackend>());
            expect(
              backend.capabilities.textureFormats,
              contains(TextureFormat.bc7RgbaUnormSrgb),
            );
            expect(
              backend.capabilities.textureFormats,
              isNot(contains(TextureFormat.astc4x4Unorm)),
            );
            final gpu = backend as GraphBackend;
            expect(
              backend.capabilities.features,
              containsAll([
                RenderFeature.scopedResources,
                RenderFeature.shaderCompilation,
                RenderFeature.renderGraphs,
                RenderFeature.compute,
                RenderFeature.storageTextures,
              ]),
            );
            final resources = gpu.createResourceScope();
            final graphs = gpu.createGraphCompiler();
            final shaders = gpu.createShaderCompiler();
            final pending = resources.createBuffer(
              BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
            );
            final rejected = expectLater(pending, throwsStateError);
            // Allow the method channel to accept the allocation, then close it.
            await Future<void>.delayed(Duration.zero);
            final closing = backend.close();
            final outcome = releaseFails
                ? expectLater(
                    closing,
                    throwsA(
                      isA<ScopeCleanupException>().having(
                        (e) => e.errors.length,
                        'cleanup errors',
                        closeFails ? 2 : 1,
                      ),
                    ),
                  )
                : closing;
            expect(resources.isClosed, isTrue);
            expect(graphs.isClosed, isTrue);
            expect(shaders.isClosed, isTrue);
            expect(events, ['resource.1']);
            final bytes = ByteData(56)
              ..setUint32(0, 2, Endian.little)
              ..setUint64(8, 2, Endian.little)
              ..setUint64(16, 32, Endian.little);
            gate.complete({'status': 0, 'bytes': bytes.buffer.asUint8List()});
            await rejected;
            await outcome;
            expect(events, ['resource.1', 'resource.6', 'close']);
            expect(backend.close(), same(closing));
            expect(() => gpu.createResourceScope(), throwsStateError);
          },
        );
      }
    });
  }
}
