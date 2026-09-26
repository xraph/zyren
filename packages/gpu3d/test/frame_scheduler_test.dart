import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('idle, coalesced requests and demand have one clock', () {
    final scheduler = FrameScheduler(maxFramesPerSecond: 60);
    expect(scheduler.tick(Duration.zero)!.delta, Duration.zero);
    expect(scheduler.tick(const Duration(seconds: 1)), isNull);
    scheduler.request();
    scheduler.request();
    expect(scheduler.tick(const Duration(seconds: 1))!.index, 1);
    expect(scheduler.tick(const Duration(seconds: 2)), isNull);
    final demand = scheduler.acquireDemand();
    expect(scheduler.tick(const Duration(seconds: 2)), isNotNull);
    expect(scheduler.tick(const Duration(seconds: 3)), isNotNull);
    demand.dispose();
    demand.dispose();
    expect(scheduler.tick(const Duration(seconds: 4)), isNull);
  });

  test('throttling and a slow frame preserve the newest request', () {
    final scheduler = FrameScheduler(maxFramesPerSecond: 10);
    scheduler.tick(Duration.zero);
    scheduler.request();
    expect(scheduler.tick(const Duration(milliseconds: 5)), isNull);
    expect(scheduler.tick(const Duration(milliseconds: 100)), isNotNull);
    scheduler.request(); // A mutation while this frame is being submitted.
    final next = scheduler.tick(const Duration(milliseconds: 500))!;
    expect(next.rawDelta, const Duration(milliseconds: 400));
    expect(next.delta, const Duration(milliseconds: 100));
    expect(scheduler.tick(const Duration(seconds: 1)), isNull);
  });

  test('hidden views stop and resume starts with zero delta', () {
    final scheduler = FrameScheduler();
    final demand = scheduler.acquireDemand();
    scheduler.tick(Duration.zero);
    scheduler.setVisible(false);
    expect(scheduler.tick(const Duration(seconds: 10)), isNull);
    scheduler.setVisible(true);
    final resumed = scheduler.tick(const Duration(seconds: 11))!;
    expect(resumed.delta, Duration.zero);
    expect(resumed.rawDelta, const Duration(seconds: 11));
    expect(resumed.elapsed, const Duration(seconds: 11));
    demand.dispose();
  });

  test('clock and FPS reject invalid inputs', () {
    expect(() => FrameScheduler(maxFramesPerSecond: 0), throwsArgumentError);
    final scheduler = FrameScheduler();
    scheduler.tick(const Duration(seconds: 2));
    expect(
      () => scheduler.tick(const Duration(seconds: 1)),
      throwsArgumentError,
    );
  });
}
