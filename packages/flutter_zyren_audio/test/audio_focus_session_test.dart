import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_audio/flutter_zyren_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/audio-session');
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
      final session = AudioFocusSession(
        suspend: () => suspended++,
        resume: () => resumed++,
        onError: (e) => fail('$e'),
        mobile: true,
      );
      addTearDown(() async {
        session.dispose();
        await session.released;
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
  test(
    'transient loss resumes, permanent and route losses require Play',
    () async {
      var resumed = 0;
      var acquired = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'acquire') {
          acquired++;
          return true;
        }
        return null;
      });
      final session = AudioFocusSession(
        suspend: () {},
        resume: () => resumed++,
        onError: (e) => fail('$e'),
        mobile: true,
      );
      addTearDown(() async {
        session.dispose();
        await session.released;
        messenger.setMockMethodCallHandler(channel, null);
      });
      Future<void> event(String state) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('focus', state),
          ),
          (_) => done.complete(),
        );
        await done.future;
      }

      expect(await session.play(), true);
      await event('transientLoss');
      expect(session.allowed, false);
      expect(session.wantsPlayback, true);
      await event('gain');
      expect(resumed, 2);
      await event('loss');
      await event('gain');
      expect(resumed, 2);
      expect(session.wantsPlayback, false);
      await session.play();
      await event('routeLost');
      await event('gain');
      expect(resumed, 3);
      expect(session.wantsPlayback, false);
      await session.setForeground(false);
      expect(await session.play(), false);
      expect(acquired, 3);
      await event('gain');
      expect(acquired, 3);
      await session.setForeground(true);
      expect(resumed, 4);
    },
  );

  test('one owner survives disposal until native release completes', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'release') await release.future;
      return call.method == 'acquire' ? true : null;
    });
    AudioFocusSession make() => AudioFocusSession(
      suspend: () {},
      resume: () {},
      onError: (e) => fail('$e'),
      mobile: true,
    );
    final first = make();
    expect(make, throwsStateError);
    first.dispose();
    first.dispose();
    expect(make, throwsStateError);
    release.complete();
    await first.released;
    final replacement = make();
    expect(await replacement.play(), true);
    replacement.dispose();
    await replacement.released;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'late acquisition cannot resume after pause or a newer request',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final requests = <Completer<bool>>[];
      var resumed = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'acquire') return null;
        final pending = Completer<bool>();
        requests.add(pending);
        return pending.future;
      });
      final session = AudioFocusSession(
        suspend: () {},
        resume: () => resumed++,
        onError: (e) => fail('$e'),
        mobile: true,
      );
      addTearDown(() async {
        session.dispose();
        await session.released;
        messenger.setMockMethodCallHandler(channel, null);
      });
      final first = session.play();
      await Future<void>.delayed(Duration.zero);
      await session.pause();
      requests[0].complete(true);
      expect(await first, false);
      expect(resumed, 0);
      final older = session.play();
      await Future<void>.delayed(Duration.zero);
      final newer = session.play();
      await Future<void>.delayed(Duration.zero);
      requests[2].complete(true);
      expect(await newer, true);
      requests[1].complete(false);
      expect(await older, false);
      expect(session.allowed, true);
      expect(resumed, 1);
    },
  );

  test('release failure reports once and frees ownership', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'release') {
        throw PlatformException(code: 'releaseFailure');
      }
      return true;
    });
    final errors = <Object>[];
    AudioFocusSession make() => AudioFocusSession(
      suspend: () {},
      resume: () {},
      onError: errors.add,
      mobile: true,
    );
    final first = make();
    first.dispose();
    first.dispose();
    await first.released;
    expect(errors, hasLength(1));
    final next = make();
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    next.dispose();
    await next.released;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'desktop sessions never acquire native focus or compete for a handler',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => fail('desktop invoked native focus'),
      );
      var resumed = 0;
      AudioFocusSession make() => AudioFocusSession(
        suspend: () {},
        resume: () => resumed++,
        onError: (e) => fail('$e'),
        mobile: false,
      );
      final first = make(), second = make();
      expect(first.allowed, true);
      expect(await first.play(), true);
      expect(await second.play(), true);
      await first.setForeground(false);
      expect(await first.play(), false);
      await first.setForeground(true);
      expect(resumed, 3);
      await first.pause();
      first.dispose();
      second.dispose();
      await Future.wait([first.released, second.released]);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
  test(
    'state listeners observe intent, native interruptions and disposal',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'acquire' ? true : null,
      );
      final session = AudioFocusSession(
        suspend: () {},
        resume: () {},
        onError: (e) => fail('$e'),
        mobile: true,
      );
      final states = <(bool, bool, bool)>[];
      final cancel = session.addStateListener(
        () => states.add((
          session.foreground,
          session.allowed,
          session.wantsPlayback,
        )),
      );
      Future<void> event(String state) async {
        final done = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('focus', state),
          ),
          (_) => done.complete(),
        );
        await done.future;
      }

      await session.play();
      await event('transientLoss');
      await event('gain');
      await event('routeLost');
      await session.setForeground(false);
      await session.setForeground(true);
      await session.pause();
      session.dispose();
      await session.released;
      expect(states, [
        (true, false, true),
        (true, true, true),
        (true, false, true),
        (true, true, true),
        (true, false, false),
        (false, false, false),
        (true, false, false),
        (true, false, false),
      ]);
      cancel();
      cancel();
      expect(() => session.addStateListener(() {}), throwsStateError);
      messenger.setMockMethodCallHandler(channel, null);
    },
  );

  test(
    'listeners are bounded, removable and safe to cancel during notification',
    () async {
      final session = AudioFocusSession(
        suspend: () {},
        resume: () {},
        onError: (e) => fail('$e'),
        mobile: false,
      );
      final cancel = <void Function()>[];
      for (var i = 0; i < 32; i++) {
        cancel.add(session.addStateListener(() {}));
      }
      expect(() => session.addStateListener(() {}), throwsStateError);
      for (final remove in cancel) {
        remove();
        remove();
      }
      var called = 0;
      late void Function() removeSecond;
      session.addStateListener(() => removeSecond());
      removeSecond = session.addStateListener(() => called++);
      await session.play();
      expect(called, 0);
      session.dispose();
      await session.released;
    },
  );
}
