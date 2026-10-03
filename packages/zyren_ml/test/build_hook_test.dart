import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as hook;

void main() {
  for (final target in [OS.android, OS.iOS]) {
    test('unsupported $target fails with explicit runtime recovery', () async {
      await expectLater(
        testCodeBuildHook(
          mainMethod: hook.main,
          check: (_, _) => fail('Unsupported target cannot produce assets.'),
          targetOS: target,
          targetArchitecture: Architecture.arm64,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('separately qualified mobile runtime build'),
          ),
        ),
      );
    });
  }
}
