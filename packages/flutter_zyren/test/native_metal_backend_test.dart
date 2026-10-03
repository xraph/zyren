@TestOn('mac-os')
library;

import 'dart:typed_data';
import 'dart:async';
import 'support/device_info.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';

import 'support/texture_formats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/scene-views');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'staging transport reports the displayed cover and publishes atomically',
    () async {
      final packets = <ByteData>[];
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'connect':
          case 'close':
          case 'detach':
            return null;
          case 'create':
            return {'session': 1, 'adapter': 'test native'};
          case 'gpu':
            return deviceInfoReply(call.arguments as Map);
          case 'gpuCommand':
            if ((call.arguments as Map)['kind'] == 'graph') {
              return deviceInfoReply(call.arguments as Map);
            }
            return textureFormatsReply(call);
          case 'prepare':
            return {'epoch': 1, 'texture': 1};
          case 'render':
            final args = call.arguments as Map;
            packets.add(ByteData.sublistView(args['json'] as Uint8List));
            return {
              'applied': true,
              'ready': true,
              'presented': true,
              'readbackBytes': 0,
            };
          default:
            throw StateError(call.method);
        }
      });
      final backend = await NativeMetalBackend.create(runtimeToken: 10);
      try {
        final target = await backend.prepareView(7, PhysicalSize(16, 16));
        final camera = PerspectiveCamera();
        Future<FrameOutput> draw(Scene scene) => backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(16, 16),
            target: target,
          ),
        );
        final old = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
        final initial = await draw(old);
        final candidate = Scene();
        for (var i = 0; i < 2; i++) {
          candidate.add(
            Mesh(
              BufferGeometry(
                positions: Float32List(600000 * 3),
                normals: Float32List.fromList(List.filled(600000 * 3, 1)),
                indices: [0, 1, 2],
              ),
              UnlitMaterial(),
            ),
          );
        }
        final staged = await draw(candidate);
        expect(packets.last.getUint32(0, Endian.little), 4);
        expect(staged.stats.admission!.candidateReady, isFalse);
        expect(
          staged.stats.admission!.presentedIdentities,
          initial.stats.admission!.presentedIdentities,
        );
        expect(staged.stats.drawCalls, initial.stats.drawCalls);
        final published = await draw(candidate);
        expect(published.stats.admission!.candidateReady, isTrue);
        expect(published.stats.admission!.presentedIdentities.length, 2);
        expect(
          published.stats.uploadedBytes,
          lessThanOrEqualTo(64 * 1024 * 1024),
        );
      } finally {
        await backend.close();
      }
    },
  );
  test(
    'native device loss reaches the controller without hiding other errors',
    () async {
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'connect':
          case 'close':
            return null;
          case 'create':
            return {'session': 1, 'adapter': 'test Metal'};
          case 'gpuCommand':
            if ((call.arguments as Map)['kind'] == 'graph') {
              return deviceInfoReply(call.arguments as Map);
            }
            return textureFormatsReply(call);
          case 'fault':
            throw PlatformException(
              code: (call.arguments as Map)['failureCode'] as String,
              message: 'Native failure',
            );
          default:
            throw StateError(call.method);
        }
      });
      final backend = await NativeMetalBackend.create(runtimeToken: 10);
      try {
        for (final (code, expected) in [
          ('deviceLost', SceneIssueCodes.deviceLost),
          ('frameDeferred', SceneIssueCodes.frameDeferred),
          ('validationFailed', SceneIssueCodes.renderFailed),
        ]) {
          await expectLater(
            backend.request('fault', {'failureCode': code}),
            throwsA(
              isA<SceneException>().having(
                (e) => e.issue.code,
                'code',
                expected,
              ),
            ),
          );
        }
      } finally {
        await backend.close();
      }
    },
  );
  test('MSAA feature admission follows the adapter sample counts', () async {
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final samples in [
      <int>[1],
      <int>[1, 4],
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'connect':
          case 'close':
            return null;
          case 'create':
            return {
              'session': 1,
              'adapter': 'test Metal',
              'driverInfo': 'test driver',
            };
          case 'gpuCommand':
            if ((call.arguments as Map)['kind'] == 'graph') {
              return deviceInfoReply(call.arguments as Map, samples: samples);
            }
            return textureFormatsReply(call);
          default:
            throw StateError(call.method);
        }
      });
      final backend = await NativeMetalBackend.create(runtimeToken: 10);
      expect(
        backend.capabilities.supports(RenderFeature.multisampleAntialiasing),
        samples.contains(4),
      );
      expect(
        backend.capabilities.supports(RenderFeature.standardMaterials),
        isTrue,
      );
      expect(backend.capabilities.supports(RenderFeature.bloom), isTrue);
      await backend.close();
    }
  });
  test(
    'superseded applied frames update geometry residency and capture shares it',
    () async {
      final packets = <ByteData>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'gpuCommand':
                return textureFormatsReply(call);
              case 'connect':
                return null;
              case 'gpu':
                return deviceInfoReply(call.arguments as Map);
              case 'create':
                return {'session': 1, 'adapter': 'test Metal'};
              case 'prepare':
                return {'epoch': 1};
              case 'render':
              case 'capture':
                final args = call.arguments as Map;
                packets.add(ByteData.sublistView(args['json'] as Uint8List));
                return {
                  'applied': true,
                  'ready': packets.length != 1,
                  'readbackBytes': call.method == 'capture' ? 1024 : 0,
                  if (call.method == 'capture') 'pixels': Uint8List(1024),
                };
              case 'close':
                return null;
              default:
                throw StateError(call.method);
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final backend = await NativeMetalBackend.create(runtimeToken: 10);
      expect(backend.capabilities.limits.sampleCounts, {1, 4});
      final target = await backend.prepareView(7, PhysicalSize(16, 16));
      final scene = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
      FrameSubmission frame() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(16, 16),
        target: target,
      );
      await expectLater(
        backend.render(frame()),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.frameDeferred,
          ),
        ),
      );
      expect(packets.first.getUint32(44, Endian.little), 1);
      final output = await backend.render(frame());
      expect(packets.last.getUint32(44, Endian.little), 0);
      expect(output.stats.presentationPath, PresentationPath.nativeView);
      expect(output.stats.readbackBytes, 0);
      final capture = await backend.render(
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(16, 16),
        ),
      );
      expect(capture, isA<ReadbackOutput>());
      expect(capture.stats.readbackBytes, 1024);
      expect(packets.last.getUint32(44, Endian.little), 0);
      final mesh = scene.children.single as Mesh;
      scene.remove(mesh);
      await backend.render(frame());
      expect(packets.last.getUint32(48, Endian.little), 0);
      scene.add(mesh);
      await backend.render(frame());
      expect(packets.last.getUint32(44, Endian.little), 1);
      await backend.close();
    },
  );
  test(
    'close observes errors immediately while an in-flight frame settles',
    () async {
      final gate = Completer<Object>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'gpuCommand':
                return textureFormatsReply(call);
              case 'connect':
                return null;
              case 'gpu':
                return deviceInfoReply(call.arguments as Map);
              case 'create':
                return {'session': 1, 'adapter': 'test Metal'};
              case 'prepare':
                return {'epoch': 1};
              case 'render':
                return gate.future;
              case 'close':
                throw PlatformException(
                  code: 'closeFailed',
                  message: 'test close failure',
                );
              default:
                throw StateError(call.method);
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final backend = await NativeMetalBackend.create(runtimeToken: 10);
      expect(backend.capabilities.limits.sampleCounts, {1, 4});
      final target = await backend.prepareView(7, PhysicalSize(16, 16));
      final rendering = backend.render(
        FrameSubmission.capture(
          scene: Scene(),
          camera: PerspectiveCamera(),
          size: PhysicalSize(16, 16),
          target: target,
        ),
      );
      final closing = backend.close();
      final observed = expectLater(closing, throwsA(isA<SceneException>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete({'applied': true, 'ready': true, 'readbackBytes': 0});
      await rendering;
      await observed;
      expect(backend.close(), same(closing));
    },
  );
}
