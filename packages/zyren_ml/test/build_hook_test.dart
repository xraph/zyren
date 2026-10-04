import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';
import '../hook/build.dart' as hook;
import '../hook/runtime_target.dart';

void main() {
  test(
    'mobile selection preserves device/simulator slices and explicit minima',
    () {
      expect(
        RuntimeTarget.select(
          OS.android,
          Architecture.arm64,
          androidApi: 24,
        ).key,
        'android-arm64',
      );
      expect(
        RuntimeTarget.select(OS.android, Architecture.ia32, androidApi: 24).key,
        'android-ia32',
      );
      expect(
        RuntimeTarget.select(
          OS.iOS,
          Architecture.arm64,
          iosSdk: IOSSdk.iPhoneOS,
          iosVersion: 16,
        ).key,
        'ios-arm64',
      );
      expect(
        RuntimeTarget.select(
          OS.iOS,
          Architecture.arm64,
          iosSdk: IOSSdk.iPhoneSimulator,
          iosVersion: 16,
        ).key,
        'ios-arm64-simulator',
      );
      expect(
        RuntimeTarget.select(
          OS.iOS,
          Architecture.x64,
          iosSdk: IOSSdk.iPhoneSimulator,
          iosVersion: 16,
        ).key,
        'ios-x64-simulator',
      );
      expect(
        () => RuntimeTarget.select(
          OS.iOS,
          Architecture.x64,
          iosSdk: IOSSdk.iPhoneOS,
          iosVersion: 16,
        ),
        throwsUnsupportedError,
      );
    },
  );
  test('declared Apple minimum is validated rather than silently lowered', () {
    expect(RuntimeTarget.iosDeploymentVersion(15, 16), 16);
    expect(RuntimeTarget.iosDeploymentVersion(16, null), 16);
    for (final invalid in [15, '16', 100, 15.1]) {
      expect(
        () => RuntimeTarget.iosDeploymentVersion(15, invalid),
        throwsArgumentError,
      );
    }
    expect(
      () => RuntimeTarget.iosDeploymentVersion(18, 16),
      throwsArgumentError,
    );
  });
  for (final os in [OS.android, OS.iOS]) {
    test('incompatible $os minimum rejects before producing assets', () async {
      await expectLater(
        testCodeBuildHook(
          mainMethod: hook.main,
          check: (_, _) => fail('No incompatible assets.'),
          targetOS: os,
          targetArchitecture: Architecture.arm64,
          targetAndroidNdkApi: 23,
          targetIOSVersion: 15,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'reason',
            contains('requires'),
          ),
        ),
      );
    });
  }
  if (Platform.environment['ZYREN_MOBILE_HOOKS'] == '1') {
    for (final target in [
      for (final arch in [
        Architecture.arm64,
        Architecture.arm,
        Architecture.x64,
        Architecture.ia32,
      ])
        (OS.android, IOSSdk.iPhoneOS, arch),
      (OS.iOS, IOSSdk.iPhoneOS, Architecture.arm64),
      (OS.iOS, IOSSdk.iPhoneSimulator, Architecture.arm64),
      (OS.iOS, IOSSdk.iPhoneSimulator, Architecture.x64),
    ]) {
      test(
        'actual ${target.$1}/${target.$2}/${target.$3} produces two linked native assets',
        () async {
          await testCodeBuildHook(
            mainMethod: hook.main,
            targetOS: target.$1,
            targetArchitecture: target.$3,
            targetIOSSdk: target.$2,
            targetIOSVersion: 16,
            targetAndroidNdkApi: 24,
            check: (_, output) async {
              final assets = output.assets.code;
              expect(assets, hasLength(2));
              for (final asset in assets) {
                expect(asset.linkMode, isA<DynamicLoadingBundled>());
                expect(
                  await File.fromUri(asset.file!).length(),
                  greaterThan(0),
                );
              }
              if (target.$1 == OS.iOS) {
                final runtime = assets.singleWhere(
                  (asset) => asset.id == 'package:zyren_ml/onnxruntime',
                );
                final symbols = await Process.run('xcrun', [
                  'nm',
                  '-gU',
                  File.fromUri(runtime.file!).path,
                ]);
                expect(symbols.exitCode, 0, reason: '${symbols.stderr}');
                expect(symbols.stdout, contains(' _OrtGetApiBase'));
                final dependencies = await Process.run('xcrun', [
                  'otool',
                  '-L',
                  File.fromUri(runtime.file!).path,
                ]);
                expect(dependencies.exitCode, 0);
                expect(
                  dependencies.stdout,
                  isNot(contains('onnxruntime.framework')),
                );
              }
            },
          );
        },
        timeout: const Timeout(Duration(minutes: 3)),
      );
    }
  }
}
