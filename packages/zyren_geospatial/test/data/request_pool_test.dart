import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'identity_test.dart' show key, resource;

void main() {
  test(
    'queue and consumer overflow cannot allocate extra physical work',
    () async {
      final pool = GeoRequestPool(
        maxConcurrent: 1,
        maxQueued: 1,
        maxConsumers: 3,
        maxInFlightBytes: 4,
      );
      final gate = Completer<GeoResource>();
      Future<GeoResource> submit(String id, int bytes) => pool.run(
        id,
        'sea',
        work: (_) => gate.future,
        cancellation: LoadCancellationSource(),
        reservationBytes: bytes,
      );
      final first = submit('a', 4),
          queued = submit('b', 4),
          shared = submit('a', 4);
      await expectLater(submit('c', 4), throwsA(isA<GeoDataException>()));
      await expectLater(submit('a', 4), throwsA(isA<GeoDataException>()));
      await expectLater(submit('a', 5), throwsA(isA<GeoDataException>()));
      expect(pool.stats.active, 1);
      expect(pool.stats.queued, 1);
      expect(pool.stats.consumers, 3);
      gate.complete(resource(key()));
      await Future.wait([first, queued, shared]);
      await pool.close();
    },
  );
  test(
    'shared consumers cancel independently and physical slots drain before reuse',
    () async {
      final pool = GeoRequestPool(
        maxConcurrent: 1,
        maxPerSource: 1,
        maxQueued: 4,
        maxInFlightBytes: 4,
      );
      final first = LoadCancellationSource(), second = LoadCancellationSource();
      final gate = Completer<GeoResource>();
      var calls = 0;
      Future<GeoResource> work(LoadCancellation token) {
        calls++;
        return gate.future;
      }

      final one = pool.run(
        'key',
        'sea',
        work: work,
        cancellation: first,
        reservationBytes: 4,
      );
      final two = pool.run(
        'key',
        'sea',
        work: work,
        cancellation: second,
        reservationBytes: 4,
      );
      final cancelled = expectLater(
        one,
        throwsA(
          isA<GeoDataException>().having(
            (e) => e.code,
            'code',
            GeoDataError.cancelled,
          ),
        ),
      );
      first.cancel();
      await cancelled;
      expect(pool.stats.active, 1);
      expect(pool.stats.consumers, 1);
      gate.complete(resource(key()));
      expect((await two).key, key());
      expect(calls, 1);
      await pool.close();
    },
  );
  test(
    'all-consumer cancellation retains admission until the physical operation settles',
    () async {
      final pool = GeoRequestPool(
        maxConcurrent: 1,
        maxPerSource: 1,
        maxQueued: 4,
        maxInFlightBytes: 4,
      );
      final cancellation = LoadCancellationSource(),
          gate = Completer<GeoResource>();
      var started = false;
      final first = pool.run(
        'a',
        'sea',
        work: (_) => gate.future,
        cancellation: cancellation,
        reservationBytes: 4,
      );
      final cancelled = expectLater(first, throwsA(isA<GeoDataException>()));
      cancellation.cancel();
      await cancelled;
      final second = pool.run(
        'a',
        'sea',
        work: (_) async {
          started = true;
          return resource(key());
        },
        cancellation: LoadCancellationSource(),
        reservationBytes: 4,
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, isFalse);
      expect(pool.stats.reservedBytes, 4);
      expect(pool.stats.queued, 1);
      gate.complete(resource(key()));
      await second;
      expect(started, isTrue);
      await pool.close();
      expect(pool.stats.reservedBytes, 0);
    },
  );
  test(
    'per-source slots admit another source and closing drains all accepted work',
    () async {
      final pool = GeoRequestPool(
        maxConcurrent: 2,
        maxPerSource: 1,
        maxQueued: 4,
        maxInFlightBytes: 8,
      );
      final gate = Completer<GeoResource>();
      var sameStarted = false, otherStarted = false;
      final first = pool.run(
        'a',
        'sea',
        work: (_) => gate.future,
        cancellation: LoadCancellationSource(),
        reservationBytes: 4,
      );
      final same = pool.run(
        'b',
        'sea',
        work: (_) async {
          sameStarted = true;
          return resource(key());
        },
        cancellation: LoadCancellationSource(),
        reservationBytes: 4,
      );
      final other = pool.run(
        'c',
        'land',
        work: (_) async {
          otherStarted = true;
          return resource(key());
        },
        cancellation: LoadCancellationSource(),
        reservationBytes: 4,
      );
      await other;
      expect(otherStarted, isTrue);
      expect(sameStarted, isFalse);
      final a = expectLater(first, throwsA(isA<GeoDataException>()));
      final b = expectLater(same, throwsA(isA<GeoDataException>()));
      var closed = false;
      final close = pool.close().then((_) => closed = true);
      await a;
      await b;
      expect(closed, isFalse);
      gate.complete(resource(key()));
      await close;
      expect(pool.stats.active, 0);
      expect(sameStarted, isFalse);
    },
  );
}
