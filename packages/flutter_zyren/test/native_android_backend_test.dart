import 'dart:async';
import 'support/device_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:flutter_zyren/src/presentation/native_android_presenter.dart';

import 'support/texture_formats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/android-surfaces');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });
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
            return deviceInfoReply(call.arguments as Map, executedMeshDraws: 1);
          case 'gpuCommand':
            if ((call.arguments as Map)['kind'] == 'graph') {
              return deviceInfoReply(
                call.arguments as Map,
                executedMeshDraws: 1,
              );
            }
            return textureFormatsReply(call);
          case 'prepare':
            return {'epoch': 1, 'texture': 1};
          case 'render':
            final args = call.arguments as Map;
            packets.add(ByteData.sublistView(args['scene'] as Uint8List));
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
      final backend = await NativeAndroidBackend.create(runtimeToken: 10);
      try {
        final presenter = const NativeAndroidPresenterFactory().create(backend);
        final target = await presenter.prepare(PhysicalSize(16, 16));
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
        expect(published.stats.profile!.executedMeshDraws, 1);
        expect(published.stats.drawCalls, initial.stats.drawCalls);
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
            return {'session': 1, 'adapter': 'test Android'};
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
      final backend = await NativeAndroidBackend.create(runtimeToken: 10);
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
              'adapter': 'test Android',
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
      final backend = await NativeAndroidBackend.create(runtimeToken: 10);
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
  test('applied superseded frames retain geometry through remount', () async {
    final packets = <ByteData>[];
    final detached = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map?;
      switch (call.method) {
        case 'gpuCommand':
          return textureFormatsReply(call);
        case 'connect':
          return null;
        case 'gpu':
          return deviceInfoReply(call.arguments as Map);
        case 'create':
          return {
            'session': 1,
            'adapter': 'test Vulkan',
            'driverInfo': 'test driver',
          };
        case 'prepare':
          return {'epoch': args!['attachment'], 'texture': args['attachment']};
        case 'render':
          packets.add(ByteData.sublistView(args!['scene'] as Uint8List));
          return {
            'applied': true,
            'presented': packets.length != 1,
            'readbackBytes': 0,
          };
        case 'present':
          return true;
        case 'detach':
          detached.add(args!['attachment'] as int);
          return null;
        case 'close':
          return null;
        default:
          throw StateError(call.method);
      }
    });
    final backend = await NativeAndroidBackend.create(runtimeToken: 10);
    expect(backend.capabilities.limits.sampleCounts, {1, 4});
    final factory = const NativeAndroidPresenterFactory();
    final presenter = factory.create(backend);
    final scene = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
    Future<FrameOutput> draw(OutputTarget target) => backend.render(
      FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(16, 16),
        target: target,
      ),
    );
    final target = await presenter.prepare(PhysicalSize(16, 16));
    await expectLater(
      draw(target),
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.frameDeferred,
        ),
      ),
    );
    final output = await draw(target);
    await presenter.present(output);
    expect(output.stats.presentationPath, PresentationPath.sharedTexture);
    expect(output.stats.readbackBytes, 0);
    expect(packets.first.getUint32(44, Endian.little), 1);
    expect(packets.last.getUint32(44, Endian.little), 0);
    await presenter.dispose();
    final remounted = factory.create(backend);
    final next = await remounted.prepare(PhysicalSize(16, 16));
    final nextOutput = await draw(next);
    await remounted.present(nextOutput);
    expect(packets.last.getUint32(44, Endian.little), 0);
    expect(nextOutput.stats.surfaceEpoch, 2);
    await expectLater(
      presenter.present(nextOutput),
      throwsA(isA<SceneException>()),
    );
    await remounted.dispose();
    expect(detached, [1, 2]);
    expect(backend.capabilities.supports(RenderFeature.rgbaReadback), false);
    await expectLater(
      draw(const ReadbackTarget()),
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.unsupportedFeature,
        ),
      ),
    );
    await backend.close();
  });
  test(
    'closing waits for an in-flight frame and rejects later rendering',
    () async {
      final frameGate = Completer<Object>();
      var closes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'gpuCommand':
            return textureFormatsReply(call);
          case 'connect':
            return null;
          case 'gpu':
            return deviceInfoReply(call.arguments as Map);
          case 'create':
            return {'session': 1, 'adapter': 'test Vulkan', 'driverInfo': ''};
          case 'prepare':
            return {'epoch': 1, 'texture': 1};
          case 'render':
            return frameGate.future;
          case 'close':
            closes++;
            return null;
          default:
            throw StateError(call.method);
        }
      });
      final backend = await NativeAndroidBackend.create(runtimeToken: 10);
      expect(backend.capabilities.limits.sampleCounts, {1, 4});
      final presenter = const NativeAndroidPresenterFactory().create(backend);
      final target = await presenter.prepare(PhysicalSize(16, 16));
      final submission = FrameSubmission.capture(
        scene: Scene(),
        camera: PerspectiveCamera(),
        size: PhysicalSize(16, 16),
        target: target,
      );
      final drawing = backend.render(submission);
      await expectLater(
        backend.render(submission),
        throwsA(isA<SceneException>()),
      );
      final closing = backend.close();
      var closed = false;
      closing.then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      frameGate.complete({
        'applied': true,
        'presented': false,
        'readbackBytes': 0,
      });
      await expectLater(drawing, throwsA(isA<SceneException>()));
      await closing;
      expect(backend.close(), same(closing));
      expect(closes, 1);
      await expectLater(
        backend.render(submission),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.disposed,
          ),
        ),
      );
    },
  );
  test('detaching while prepare is pending rejects its late target', () async {
    final gate = Completer<Object>();
    var detached = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'gpuCommand':
          return textureFormatsReply(call);
        case 'connect':
          return null;
        case 'gpu':
          return deviceInfoReply(call.arguments as Map);
        case 'create':
          return {'session': 1, 'adapter': 'Vulkan'};
        case 'prepare':
          return gate.future;
        case 'detach':
          detached++;
          return null;
        case 'close':
          return null;
        default:
          throw StateError(call.method);
      }
    });
    final backend = await NativeAndroidBackend.create(runtimeToken: 10);
    expect(backend.capabilities.limits.sampleCounts, {1, 4});
    final presenter = const NativeAndroidPresenterFactory().create(backend);
    final pending = presenter.prepare(PhysicalSize(16, 16));
    final rejected = expectLater(
      pending,
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.frameDeferred,
        ),
      ),
    );
    await presenter.dispose();
    gate.complete({'epoch': 1, 'texture': 9});
    await rejected;
    await presenter.dispose();
    expect(detached, 1);
    await backend.close();
  });
  test('surface keys cannot cross renderer ownership', () async {
    var next = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'gpuCommand':
          return textureFormatsReply(call);
        case 'connect':
          return null;
        case 'gpu':
          return deviceInfoReply(call.arguments as Map);
        case 'create':
          return {'session': ++next, 'adapter': 'Vulkan'};
        case 'prepare':
          return {'epoch': 1, 'texture': 9};
        case 'detach':
        case 'close':
          return null;
        default:
          throw StateError('Unexpected native call: ${call.method}');
      }
    });
    final first = await NativeAndroidBackend.create(runtimeToken: 10);
    final second = await NativeAndroidBackend.create(runtimeToken: 10);
    final presenter = const NativeAndroidPresenterFactory().create(first);
    final target = await presenter.prepare(PhysicalSize(16, 16));
    await expectLater(
      second.render(
        FrameSubmission.capture(
          scene: Scene(),
          camera: PerspectiveCamera(),
          size: PhysicalSize(16, 16),
          target: target,
        ),
      ),
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.presentationUnavailable,
        ),
      ),
    );
    await presenter.dispose();
    await first.close();
    await second.close();
  });
}
