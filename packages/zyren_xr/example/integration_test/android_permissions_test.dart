import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_xr/flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android camera denial and explicit retry', (tester) async {
    expect(Platform.isAndroid, isTrue);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Camera permission probe'))),
    );
    await tester.runAsync(() async {
      const transport = MethodChannelXrTransport();
      final session = await XrSession.create(transport);
      try {
        await expectLater(
          session.start(),
          throwsA(
            isA<XrException>().having(
              (e) => e.code,
              'code',
              'permissionDenied',
            ),
          ),
        );
        debugPrint('XR_PERMISSION_DENIED_CONFIRMED');
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while ((await XrSession.capabilities(transport)).cameraPermission !=
            XrCameraPermission.authorized) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Grant Camera to continue the explicit retry check.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        await session.start();
        expect((await session.snapshot()).state, XrSessionState.running);
        await session.pause();
        expect((await session.snapshot()).frame, isNull);
        debugPrint('XR_PERMISSION_RETRY_CONFIRMED');
      } finally {
        await session.dispose();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
