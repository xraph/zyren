import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_xr/flutter.dart';
import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const transport = MethodChannelXrTransport();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(transport.channel, null));

  test(
    'channel serializes capabilities and preserves native denial details',
    () async {
      messenger.setMockMethodCallHandler(transport.channel, (call) async {
        if (call.method == 'capabilities') return capabilitiesMessage();
        throw PlatformException(
          code: 'permissionDenied',
          message: 'Camera denied.',
          details: {'permission': 'camera'},
        );
      });
      expect((await XrSession.capabilities(transport)).platform, 'arkit');
      await expectLater(
        transport.invoke('start', {}),
        throwsA(
          isA<XrException>()
              .having((e) => e.code, 'code', 'permissionDenied')
              .having((e) => e.details, 'details', {'permission': 'camera'}),
        ),
      );
    },
  );

  test('missing platform plugin is explicitly unavailable', () async {
    await expectLater(
      XrSession.capabilities(transport),
      throwsA(
        isA<XrException>().having((e) => e.code, 'code', 'adapterUnavailable'),
      ),
    );
  });
}
