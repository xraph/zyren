import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/rendering.dart';
import 'package:flutter_zyren/src/presentation/surface_session.dart';

void main() {
  test(
    'close during native creation retires the late attachment once',
    () async {
      final bridge = DelayedBridge();
      final session = SurfaceSession(
        bridge: bridge,
        runtimeToken: 7,
        size: PhysicalSize(63, 47),
      );
      final ready = expectLater(
        session.ready,
        throwsA(issue(SceneIssueCodes.disposed)),
      );
      await bridge.started.future;
      final close = session.close();
      bridge.created.complete(attachment());
      await close;
      await ready;
      expect(session.state, SurfaceSessionState.closed);
      expect(session.attachment, isNull);
      expect(bridge.closed, [bridge.current.key]);
      await session.close();
      expect(bridge.closed.length, 1);
    },
  );

  test('runtime mismatch fails before native surface allocation', () async {
    final bridge = DelayedBridge()..token = 8;
    final session = SurfaceSession(
      bridge: bridge,
      runtimeToken: 7,
      size: PhysicalSize(63, 47),
    );
    await expectLater(
      session.ready,
      throwsA(issue(SceneIssueCodes.presentationUnavailable)),
    );
    expect(bridge.started.isCompleted, isFalse);
    await session.close();
    expect(session.state, SurfaceSessionState.closed);
  });

  test(
    'creation folds resize and suspension into the latest desired state',
    () async {
      final bridge = DelayedBridge();
      final session = SurfaceSession(
        bridge: bridge,
        runtimeToken: 7,
        size: PhysicalSize(63, 47),
      );
      await bridge.started.future;
      final resized = session.resize(PhysicalSize(81, 59));
      final suspended = session.setSuspended(true);
      bridge.created.complete(attachment());
      await Future.wait([session.ready, resized, suspended]);
      expect(
        (session.attachment!.size.width, session.attachment!.size.height),
        (81, 59),
      );
      expect(session.state, SurfaceSessionState.suspended);
      expect(bridge.operations, ['resize:81x59@1', 'suspend:true@2']);
      await session.setSuspended(false);
      expect(session.state, SurfaceSessionState.ready);
      expect(session.attachment!.epoch, 3);
      await session.close();
    },
  );

  test(
    'resize storm has one operation in flight and one latest desired size',
    () async {
      final bridge = DelayedBridge();
      bridge.created.complete(attachment());
      final session = SurfaceSession(
        bridge: bridge,
        runtimeToken: 7,
        size: PhysicalSize(63, 47),
      );
      await session.ready;
      bridge.resizeGate = Completer<void>();
      final first = session.resize(PhysicalSize(65, 49));
      await bridge.resizing.future;
      Future<void>? latest;
      for (var i = 0; i < 10000; i++) {
        latest = session.resize(PhysicalSize(81, 60 + i % 2));
      }
      expect(bridge.operations, ['resize:65x49@1']);
      bridge.resizeGate!.complete();
      await Future.wait([first, latest!]);
      expect(bridge.operations, ['resize:65x49@1', 'resize:81x61@2']);
      expect(session.attachment!.epoch, 3);
      await session.close();
    },
  );

  test('close waits for resize and does not expose its late result', () async {
    final bridge = DelayedBridge()..created.complete(attachment());
    final session = SurfaceSession(
      bridge: bridge,
      runtimeToken: 7,
      size: PhysicalSize(63, 47),
    );
    await session.ready;
    bridge.resizeGate = Completer<void>();
    final resize = session.resize(PhysicalSize(65, 49));
    await bridge.resizing.future;
    final closing = session.close();
    expect(session.attachment, isNull);
    expect(bridge.closed, isEmpty);
    bridge.resizeGate!.complete();
    await Future.wait([resize, closing]);
    expect(session.attachment, isNull);
    expect(session.state, SurfaceSessionState.closed);
    expect(bridge.closed.length, 1);
    await expectLater(
      session.resize(PhysicalSize(32, 32)),
      throwsA(issue(SceneIssueCodes.disposed)),
    );
  });

  test(
    'a failed mutation cannot start more native work before close',
    () async {
      final bridge = DelayedBridge()..created.complete(attachment());
      final session = SurfaceSession(
        bridge: bridge,
        runtimeToken: 7,
        size: PhysicalSize(63, 47),
      );
      await session.ready;
      bridge.resizeFailure = StateError('native resize failed');
      await expectLater(session.resize(PhysicalSize(81, 59)), throwsStateError);
      expect(session.state, SurfaceSessionState.failed);
      expect(session.attachment, isNull);
      await expectLater(session.resize(PhysicalSize(82, 60)), throwsStateError);
      expect(bridge.operations.length, 1);
      await session.close();
      expect(bridge.closed.length, 1);
    },
  );
  test(
    'close during initial resize cannot complete readiness successfully',
    () async {
      final bridge = DelayedBridge()..resizeGate = Completer<void>();
      final session = SurfaceSession(
        bridge: bridge,
        runtimeToken: 7,
        size: PhysicalSize(63, 47),
      );
      final ready = expectLater(
        session.ready,
        throwsA(issue(SceneIssueCodes.disposed)),
      );
      await bridge.started.future;
      final resize = expectLater(
        session.resize(PhysicalSize(81, 59)),
        throwsA(issue(SceneIssueCodes.disposed)),
      );
      bridge.created.complete(attachment());
      await bridge.resizing.future;
      final close = session.close();
      bridge.resizeGate!.complete();
      await Future.wait([ready, resize, close]);
      expect(session.state, SurfaceSessionState.closed);
      expect(bridge.closed.length, 1);
    },
  );
  test(
    'a request in the completion microtask still reaches native state',
    () async {
      final bridge = DelayedBridge()..created.complete(attachment());
      final session = SurfaceSession(
        bridge: bridge,
        runtimeToken: 7,
        size: PhysicalSize(63, 47),
      );
      await session.ready;
      final first = session.resize(PhysicalSize(63, 47));
      late Future<void> lateResize;
      scheduleMicrotask(() {
        lateResize = session.resize(PhysicalSize(81, 59));
      });
      await first;
      await lateResize;
      expect(
        (session.attachment!.size.width, session.attachment!.size.height),
        (81, 59),
      );
      expect(bridge.operations, ['resize:81x59@1']);
      await session.close();
    },
  );
}

Matcher issue(String code) =>
    isA<SceneException>().having((e) => e.issue.code, 'code', code);

final class TestKey implements SurfaceKey {}

SurfaceAttachment attachment() => SurfaceAttachment(
  key: TestKey(),
  textureId: 23,
  epoch: 1,
  size: PhysicalSize(63, 47),
  suspended: false,
);

// Only the asynchronous platform boundary is replaced. The session under test
// owns coalescing, cancellation and attachment visibility.
class DelayedBridge implements SurfaceBridge {
  int token = 7;
  final started = Completer<void>(), resizing = Completer<void>();
  final created = Completer<SurfaceAttachment>();
  Completer<void>? resizeGate;
  Object? resizeFailure;
  late SurfaceAttachment current;
  final operations = <String>[];
  final closed = <SurfaceKey>[];
  @override
  Future<int> runtimeToken() async => token;
  @override
  Future<SurfaceAttachment> create(PhysicalSize size) async {
    started.complete();
    return current = await created.future;
  }

  @override
  Future<SurfaceAttachment> resize(
    SurfaceAttachment surface,
    PhysicalSize size,
  ) async {
    expect(surface.epoch, current.epoch);
    operations.add('resize:${size.width}x${size.height}@${surface.epoch}');
    if (resizeFailure != null) throw resizeFailure!;
    if (!resizing.isCompleted) resizing.complete();
    await resizeGate?.future;
    return current = SurfaceAttachment(
      key: surface.key,
      textureId: surface.textureId,
      epoch: surface.epoch + 1,
      size: size,
      suspended: surface.suspended,
    );
  }

  @override
  Future<SurfaceAttachment> suspend(
    SurfaceAttachment surface,
    bool suspended,
  ) async {
    expect(surface.epoch, current.epoch);
    operations.add('suspend:$suspended@${surface.epoch}');
    return current = SurfaceAttachment(
      key: surface.key,
      textureId: surface.textureId,
      epoch: surface.epoch + (suspended ? 1 : 0),
      size: surface.size,
      suspended: suspended,
    );
  }

  @override
  Future<void> close(SurfaceAttachment surface) async {
    closed.add(surface.key);
  }
}
