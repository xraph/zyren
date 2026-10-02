import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren_xr/zyren_xr.dart';
import 'fixtures.dart';

void main() {
  test(
    'hardware depth support does not imply camera or occlusion support',
    () async {
      final transport = RecordingTransport();
      final capabilities = await XrSession.capabilities(transport);
      expect(capabilities.sceneDepthHardware, isTrue);
      expect(capabilities.cameraPresentation, isFalse);
      expect(capabilities.depthOcclusion, isFalse);
      expect(transport.calls.single.$1, 'capabilities');
    },
  );

  test('limited tracking, lighting and frame clock remain explicit', () async {
    final transport = RecordingTransport()
      ..current = snapshotMessage(tracking: 'limited');
    final session = await XrSession.create(transport);
    final snapshot = await session.snapshot();
    expect(snapshot.state, XrSessionState.running);
    expect(snapshot.frame!.tracking, XrTrackingState.limited);
    expect(snapshot.frame!.trackingReason, 'initializing');
    expect(snapshot.frame!.ageAt(snapshot.nativeTimestamp), closeTo(0.1, 1e-9));
    expect(snapshot.frame!.light!.ambientIntensity, 900);
    expect(snapshot.frame!.anchors, isEmpty);
    expect(() => snapshot.frame!.intrinsics[0] = 0, throwsUnsupportedError);
  });

  test('pause and disposal can cancel a pending permission request', () async {
    final transport = RecordingTransport();
    final session = await XrSession.create(transport);
    final pending = Completer<Object?>();
    transport.handler = (method, _) =>
        method == 'start' ? pending.future : null;
    final starting = session.start();
    final failure = expectLater(
      starting,
      throwsA(isA<XrException>().having((e) => e.code, 'code', 'disposed')),
    );
    await session.pause();
    await session.dispose();
    pending.complete();
    await failure;
    expect(transport.calls.map((e) => e.$1), [
      'create',
      'start',
      'pause',
      'dispose',
    ]);
    await session.dispose();
    expect(transport.calls.where((e) => e.$1 == 'dispose').length, 1);
    await expectLater(session.snapshot(), throwsA(isA<XrException>()));
  });

  test(
    'duplicate starts fail and native failure does not lock future starts',
    () async {
      final transport = RecordingTransport();
      final session = await XrSession.create(transport);
      final pending = Completer<Object?>();
      transport.handler = (method, _) =>
          method == 'start' ? pending.future : null;
      final start = session.start();
      final failure = expectLater(start, throwsA(isA<XrException>()));
      await expectLater(
        session.start(),
        throwsA(isA<XrException>().having((e) => e.code, 'code', 'busy')),
      );
      pending.completeError(const XrException('permissionDenied', 'Denied.'));
      await failure;
      transport.handler = (_, _) => null;
      await session.start(resetTracking: true);
      expect(transport.calls.last.$2['resetTracking'], isTrue);
    },
  );

  test('failed disposal can be retried but blocks new work', () async {
    final transport = RecordingTransport();
    final session = await XrSession.create(transport);
    transport.handler = (_, _) =>
        throw const XrException('releaseFailed', 'Failed.');
    await expectLater(session.dispose(), throwsA(isA<XrException>()));
    await expectLater(
      session.start(),
      throwsA(isA<XrException>().having((e) => e.code, 'code', 'disposed')),
    );
    transport.handler = (_, _) => null;
    await session.dispose();
    expect(transport.calls.where((c) => c.$1 == 'dispose').length, 2);
  });

  test(
    'anchor actions carry native origin revision and frame identity',
    () async {
      final transport = RecordingTransport();
      final session = await XrSession.create(transport);
      final id = await session.addAnchor(
        XrPose.identity(),
        expectedRevision: 8,
        expectedFrameTimestamp: 12,
      );
      expect(id, 'anchor-1');
      expect(transport.calls.last.$2['expectedRevision'], 8);
      expect(transport.calls.last.$2['expectedFrameTimestamp'], 12);
      await session.removeAnchor(id, expectedRevision: 9);
      expect(transport.calls.last.$2['anchorId'], id);
      expect(transport.calls.last.$2['expectedRevision'], 9);
    },
  );

  test(
    'poses reject nonfinite, scaling, reflection and perspective matrices',
    () {
      for (final entry in [(0, double.nan), (0, 2.0), (0, -1.0), (3, 0.2)]) {
        final values = XrPose.identity().matrix.toList()..[entry.$1] = entry.$2;
        expect(() => XrPose(values), throwsArgumentError);
      }
      final translated = XrPose.identity().matrix.toList()..[12] = 3;
      expect(XrPose(translated).matrix[12], 3);
    },
  );

  test('paused and failed snapshots never fabricate a frame', () {
    final paused = XrSnapshot.fromMessage({
      'state': 'paused',
      'revision': 2,
      'nativeTimestamp': 14.0,
    });
    expect(paused.frame, isNull);
    final failed = XrSnapshot.fromMessage({
      'state': 'failed',
      'revision': 3,
      'nativeTimestamp': 14.0,
      'failure': {
        'code': 'nativeFailure',
        'message': 'Camera unavailable.',
        'details': {'domain': 'com.apple.arkit.error', 'code': 102},
      },
    });
    expect(failed.frame, isNull);
    expect(failed.failure!.code, 'nativeFailure');
  });

  test('malformed native data fails instead of returning success defaults', () {
    expect(() => XrCapabilities.fromMessage({}), throwsFormatException);
    final unknown = snapshotMessage()..['state'] = 'futureState';
    expect(() => XrSnapshot.fromMessage(unknown), throwsFormatException);
    final large = snapshotMessage();
    (large['frame'] as Map)['planes'] = List.filled(129, {});
    expect(() => XrSnapshot.fromMessage(large), throwsFormatException);
    final invalid = snapshotMessage();
    (invalid['frame'] as Map)['timestamp'] = double.nan;
    expect(() => XrSnapshot.fromMessage(invalid), throwsFormatException);
  });
}
