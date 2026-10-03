import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../streaming/tile_scheduler_test.dart'
    show Source, Content, camera, viewport, root, flush;

void main() {
  test(
    'cancelled old loads cannot clear retained coverage before the new selection',
    () async {
      final old = Source('old'), next = Source('next');
      final scheduler = TileScheduler<Content>(source: old);
      scheduler.update(camera(10000), viewport);
      await old.finish(root);
      final previous = scheduler.visible[root];
      scheduler.update(camera(30), viewport);
      scheduler.replaceSource(next, retainVisible: true);
      for (final request in old.requests.where((r) => !r.result.isCompleted)) {
        request.result.complete(Content());
      }
      await flush();
      expect(scheduler.visible[root], same(previous));
      scheduler.update(camera(10000), viewport);
      await next.finish(root);
      expect(scheduler.visible[root], isNot(same(previous)));
      expect(scheduler.retainingPreviousSource, isFalse);
      scheduler.dispose();
    },
  );

  test('retained replacement bytes consume the configured budget', () async {
    final source = Source(), next = Source('next');
    final scheduler = TileScheduler<Content>(
      source: source,
      budget: TileBudget(maxDecodedBytes: 100),
    );
    scheduler.update(camera(10000), viewport);
    await source.finish(root);
    final previous = scheduler.visible[root];
    scheduler.replaceSource(next, retainVisible: true);
    scheduler.update(camera(10000), viewport);
    expect(scheduler.visible[root], same(previous));
    expect(scheduler.stats.cachedBytes, 100);
    expect(next.requests, isEmpty);
    expect(scheduler.stats.budgetLimited, isTrue);
    scheduler.dispose();
  });
}
