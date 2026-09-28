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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/scene-views');
  test(
    'superseded applied frames update geometry residency and capture shares it',
    () async {
      final packets = <ByteData>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
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
