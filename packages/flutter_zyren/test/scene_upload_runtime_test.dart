@TestOn('mac-os')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren/src/presentation/native_android_presenter.dart';
import 'package:flutter_zyren/src/presentation/native_metal_presenter.dart';
import 'package:zyren/rendering.dart';

import 'support/backend_fake.dart';
import 'support/device_info.dart';
import 'support/texture_formats.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final android in [false, true]) {
    test(
      'runtime paces uploads through ${android ? 'Android' : 'Metal'} presentation',
      () async {
        debugDefaultTargetPlatformOverride = android
            ? TargetPlatform.android
            : TargetPlatform.macOS;
        final channel = MethodChannel(
          android ? 'zyren/android-surfaces' : 'zyren/scene-views',
        );
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          messenger.setMockMethodCallHandler(channel, null);
        });
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'connect' || 'close' || 'detach' => null,
            'create' => {'session': 1, 'adapter': 'test native'},
            'gpu' => deviceInfoReply(call.arguments as Map),
            'gpuCommand' => textureFormatsReply(call),
            'prepare' => {'epoch': 1, 'texture': 1},
            'render' => {
              'applied': true,
              'ready': true,
              'presented': true,
              'readbackBytes': 0,
            },
            _ => throw StateError(call.method),
          },
        );
        final runtime = SceneRuntime(
          sceneUploadBudgetBytes: 400,
          backendFactory: () => android
              ? NativeAndroidBackend.create(runtimeToken: 10)
              : NativeMetalBackend.create(runtimeToken: 10),
        );
        final backend = await runtime.createBackend();
        try {
          final target = backend is NativeMetalBackend
              ? await backend.prepareView(7, PhysicalSize(16, 16))
              : await const NativeAndroidPresenterFactory()
                    .create(backend as NativeAndroidBackend)
                    .prepare(PhysicalSize(16, 16));
          final scene = Scene()..add(Mesh(PlaneGeometry(), UnlitMaterial()));
          final camera = PerspectiveCamera();
          Future<FrameOutput> draw(Scene scene) => backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(16, 16),
              target: target,
            ),
          );
          final old = await draw(scene);
          final candidate = Scene();
          for (var i = 0; i < 5; i++) {
            candidate.add(Mesh(PlaneGeometry(), UnlitMaterial()));
          }
          final readiness = <bool>[];
          for (var i = 0; i < 3; i++) {
            final next = await draw(candidate);
            expect(next.stats.uploadedBytes, lessThanOrEqualTo(400));
            readiness.add(next.stats.admission!.candidateReady);
            if (!next.stats.admission!.candidateReady) {
              expect(
                next.stats.admission!.presentedIdentities,
                old.stats.admission!.presentedIdentities,
              );
            }
          }
          expect(readiness, [false, false, true]);
        } finally {
          await backend.close();
        }
      },
    );
  }

  test(
    'unsupported pacing closes the backend and reports the missing capability',
    () async {
      final backend = FakeBackend();
      final runtime = SceneRuntime(
        sceneUploadBudgetBytes: 400,
        backendFactory: () async => backend,
      );
      await expectLater(runtime.createBackend(), throwsUnsupportedError);
      expect(backend.closeCount, 1);
    },
  );
}
