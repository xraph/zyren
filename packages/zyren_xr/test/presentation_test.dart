import 'dart:async';
import 'package:flutter/foundation.dart';
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

  for (final nativeFailures in [0, 1]) {
    test(
      'cleanup failure retains its outcome with $nativeFailures native close failures',
      () async {
        final target = await XrPresentationController.create(
          session: session,
          transport: transport,
          runtimeToken: 42,
        );
        var nativeCloses = 0, releases = 0;
        transport.handler = (method, args) {
          if (method == 'gpuCommand') {
            final packet = ByteData.sublistView(args['bytes'] as Uint8List);
            final opcode = packet.getUint32(4, Endian.little);
            if (opcode == 6) {
              releases++;
              return {'status': 6, 'message': 'GPU release failed'};
            }
            expect(opcode, 1);
            final response = ByteData(56)
              ..setUint32(0, 2, Endian.little)
              ..setUint64(8, packet.getUint64(8, Endian.little), Endian.little)
              ..setUint64(16, 32, Endian.little);
            return {'status': 0, 'bytes': response.buffer.asUint8List()};
          }
          if (method == 'closePresenter') {
            nativeCloses++;
            if (nativeCloses <= nativeFailures) {
              throw const XrException('nativeCloseFailed', 'Retirement failed');
            }
            return null;
          }
          return reply(method, args);
        };
        await target.render(scene());
        final scope = target.gpu.createResourceScope();
        await scope.createBuffer(
          BufferDescriptor(size: 4, usage: {BufferUsage.uniform}),
        );
        expect(target.presentedCalibration, isNotNull);
        expect(target.diagnostics, isNotNull);
        Object? terminal;
        Future<void> capture(Future<void> closing) async {
          try {
            await closing;
            fail('Cleanup failure must remain visible.');
          } catch (error) {
            terminal = error;
          }
        }

        await capture(target.close());
        expect('$terminal', contains('GPU release failed'));
        if (nativeFailures > 0) {
          expect('$terminal', contains('Retirement failed'));
          await capture(target.close());
          expect('$terminal', isNot(contains('Retirement failed')));
        }
        expect(target.presentedCalibration, isNull);
        expect(target.diagnostics, isNull);
        final settled = target.close();
        final saved = terminal;
        await capture(settled);
        expect(terminal, same(saved));
        expect(target.close(), same(settled));
        expect(nativeCloses, nativeFailures + 1);
        expect(releases, 1);
        final reported = <Object>[];
        final previous = FlutterError.onError;
        try {
          FlutterError.onError = (details) => reported.add(details.exception);
          target.dispose();
          await Future<void>.delayed(Duration.zero);
        } finally {
          FlutterError.onError = previous;
        }
        expect(reported, [same(saved)]);
        expect(nativeCloses, nativeFailures + 1);
        transport.handler = reply;
      },
    );
  }

  test('opaque scene is rejected before retaining an AR frame', () async {
    await expectLater(
      presenter.render(Scene()..background = const Color3(1, 1, 1)),
      throwsArgumentError,
    );
    expect(transport.calls.where((c) => c.$1 == 'acquireFrame'), isEmpty);
  });
}
