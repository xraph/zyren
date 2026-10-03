import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_xr_probe/release.dart';

void main() {
  test(
    'presenter failure does not retain the native session or local providers',
    () async {
      final calls = <String>[];
      final failure = StateError('GPU release failed');
      final result = await releaseProbeResources(
        closeServer: () async {
          calls.add('server');
        },
        closePresenter: () async {
          calls.add('presenter');
          throw failure;
        },
        releaseLocal: [
          () {
            calls.add('provider');
          },
          () {
            calls.add('bindings');
          },
        ],
        disposeSession: () async {
          calls.add('session');
        },
      );
      expect(calls, ['server', 'presenter', 'provider', 'bindings', 'session']);
      expect(result.errors, [same(failure)]);
      expect(result.presenterClosed, isFalse);
      expect(result.sessionClosed, isTrue);
    },
  );
  test('independent failures remain available for explicit retry', () async {
    var sessionAttempts = 0;
    Future<void> session() async {
      if (++sessionAttempts == 1) throw StateError('retirement deferred');
    }

    final first = await releaseProbeResources(
      closeServer: () async {
        throw StateError('listener failed');
      },
      releaseLocal: [
        () {
          throw StateError('local cleanup failed');
        },
      ],
      disposeSession: session,
    );
    expect(first.errors, hasLength(3));
    expect(first.serverClosed, isFalse);
    expect(first.sessionClosed, isFalse);
    final retry = await releaseProbeResources(
      releaseLocal: [],
      disposeSession: session,
    );
    expect(retry.sessionClosed, isTrue);
    expect(sessionAttempts, 2);
  });
}
