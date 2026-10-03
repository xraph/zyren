import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_xr/flutter.dart';
import 'calibration_test.dart' show calibrationMessage;
import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecordingTransport transport;
  late XrSession session;
  late XrPresentationController presenter;
  var calibration = calibrationMessage();
  FutureOr<Object?> reply(String method, Map<String, Object?> args) =>
      switch (method) {
        'create' => {'sessionId': 'session-1'},
        'createPresenter' => {'presenterId': 'presenter-1'},
        'acquireFrame' => calibration,
        'presentFrame' => {...calibration, 'presented': true},
        _ => null,
      };
  Scene scene() => Scene()
    ..background = null
    ..backgroundOpacity = 0;
  setUp(() async {
    calibration = calibrationMessage();
    transport = RecordingTransport()..handler = reply;
    session = await XrSession.create(transport);
    presenter = await XrPresentationController.create(
      session: session,
      transport: transport,
      runtimeToken: 42,
    );
  });
  tearDown(() async {
    await presenter.close();
    presenter.dispose();
    await session.dispose();
  });

  test(
    'successful presentation publishes correlation and follows resize calibration',
    () async {
      final first = await presenter.render(scene());
      expect(presenter.presentedCalibration, same(first));
      expect(first.pixelWidth, 600);
      calibration = calibrationMessage(frame: 2, epoch: 2, landscape: true);
      final second = await presenter.render(scene());
      expect(second.pixelWidth, 1200);
      expect(second.epoch, 2);
      expect(transport.calls.where((c) => c.$1 == 'cancelFrame').length, 2);
      final packets = transport.calls
          .where((c) => c.$1 == 'presentFrame')
          .toList();
      expect(packets.last.$2['frameId'], 2);
      expect(packets.last.$2['revision'], 3);
    },
  );
  test(
    'native failure releases lease and preserves last presented calibration',
    () async {
      final prior = await presenter.render(scene());
      transport.handler = (method, args) {
        if (method == 'presentFrame') {
          throw const XrException('frameDeferred', 'Resized');
        }
        return reply(method, args);
      };
      await expectLater(presenter.render(scene()), throwsA(isA<XrException>()));
      expect(presenter.presentedCalibration, same(prior));
      expect(transport.calls.last.$1, 'cancelFrame');
      expect(presenter.isRendering, isFalse);
    },
  );
  test(
    'encoding or calibration failure cancels acquired native image',
    () async {
      calibration = {
        ...calibration,
        'projection': [1.0],
      };
      await expectLater(presenter.render(scene()), throwsArgumentError);
      expect(transport.calls.last.$1, 'cancelFrame');
      expect(transport.calls.where((c) => c.$1 == 'presentFrame'), isEmpty);
    },
  );
  test('mismatched presentation receipt is rejected and released', () async {
    transport.handler = (method, args) => method == 'presentFrame'
        ? {...calibration, 'presented': true, 'frameId': 999}
        : reply(method, args);
    await expectLater(presenter.render(scene()), throwsA(isA<XrException>()));
    expect(presenter.presentedCalibration, isNull);
    expect(transport.calls.last.$1, 'cancelFrame');
  });
  test('only one frame is admitted and close waits for release', () async {
    final pending = Completer<Object?>();
    transport.handler = (method, args) =>
        method == 'presentFrame' ? pending.future : reply(method, args);
    final first = presenter.render(scene());
    await Future<void>.delayed(Duration.zero);
    await expectLater(presenter.render(scene()), throwsA(isA<XrException>()));
    final closing = presenter.close();
    expect(transport.calls.where((c) => c.$1 == 'closePresenter'), isEmpty);
    pending.complete({...calibration, 'presented': true});
    await first;
    await closing;
    final methods = transport.calls.map((c) => c.$1).toList();
    expect(
      methods.indexOf('cancelFrame'),
      lessThan(methods.indexOf('closePresenter')),
    );
    expect(presenter.presentedCalibration, isNull);
  });
  test(
    'applied frame rejected by resize keeps the native packet baseline',
    () async {
      final world = scene();
      await presenter.render(world);
      transport.handler = (method, args) => method == 'presentFrame'
          ? {...calibration, 'applied': true, 'presented': false}
          : reply(method, args);
      await expectLater(presenter.render(world), throwsA(isA<XrException>()));
      transport.handler = reply;
      await presenter.render(world);
      final packets = transport.calls
          .where((c) => c.$1 == 'presentFrame')
          .map((c) => (c.$2['packet'] as Uint8List).buffer.asByteData())
          .toList();
      expect(
        packets[2].getUint64(32, Endian.little),
        packets[1].getUint64(8, Endian.little),
      );
    },
  );

  test('opaque scene is rejected before retaining an AR frame', () async {
    await expectLater(
      presenter.render(Scene()..background = const Color3(1, 1, 1)),
      throwsArgumentError,
    );
    expect(transport.calls.where((c) => c.$1 == 'acquireFrame'), isEmpty);
  });
}
