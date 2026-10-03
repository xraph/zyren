import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smaller_plugins_lab/audio_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/smaller-lab/audio-session');
  test(
    'focus denial, late grants and foreground resume obey host intent',
    () async {
      var resumed = 0, suspended = 0;
      bool granted = true;
      Completer<bool>? pending;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'acquire') {
          return pending == null ? granted : pending.future;
        }
        return null;
      });
      final session = LabAudioSession(
        suspend: () => suspended++,
        resume: () => resumed++,
        onError: (e) => fail('$e'),
        mobile: true,
      );
      addTearDown(() {
        session.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });
      expect(await session.play(), true);
      expect(resumed, 1);
      await session.setForeground(false);
      expect(session.allowed, false);
      expect(suspended, 1);
      await session.setForeground(true);
      expect(resumed, 2);
      granted = false;
      expect(await session.play(), false);
      expect(session.allowed, false);
      pending = Completer<bool>();
      final late = session.play();
      await Future<void>.delayed(Duration.zero);
      await session.setForeground(false);
      pending.complete(true);
      expect(await late, false);
      expect(session.allowed, false);
      expect(resumed, 2);
      pending = null;
      await session.pause();
      await session.setForeground(true);
      expect(resumed, 2);
      pending = Completer<bool>();
      final disposed = session.play();
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      final before = suspended;
      pending.completeError(PlatformException(code: 'lateFailure'));
      expect(await disposed, false);
      await session.pause();
      expect(suspended, before);
      expect(resumed, 2);
    },
  );
}
