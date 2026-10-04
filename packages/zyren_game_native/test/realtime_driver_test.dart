import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'support/native_game_fixture.dart';

class Activity implements ViewportActivitySource {
  final _listeners = <void Function(bool)>{};
  @override
  bool viewportActive = true;
  @override
  Stream<ScenePointerEvent> get events => const Stream.empty();
  @override
  Registration registerGesture(SceneGesture gesture) => Registration(() {});
  @override
  Registration listenViewportActivity(void Function(bool) listener) {
    _listeners.add(listener);
    return Registration(() => _listeners.remove(listener));
  }

  void active(bool value) {
    viewportActive = value;
    for (final listener in _listeners.toList()) {
      listener(value);
    }
  }
}

void main() {
  test(
    'native physics keeps stepping with no render and suspends with host',
    () async {
      final input = Activity();
      final fixture = await NativeGameFixture.create(input: input);
      try {
        final clock = fixture.simulation.session.realtimeClock!;
        final stepped = clock.measurements.firstWhere(
          (wake) => clock.advancedSteps >= 3,
        );
        await stepped.timeout(const Duration(seconds: 5));
        input.active(false);
        final tick = fixture.simulation.session.tick;
        expect(tick, greaterThanOrEqualTo(3));
        expect(fixture.physicsSteps, tick);
        expect(fixture.body.state.pose.position.x, closeTo(tick / 60, .001));
        await fixture.renderOneFrame(Duration.zero);
        await fixture.renderOneFrame(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(fixture.simulation.session.tick, tick);
        expect(fixture.simulation.session.droppedSeconds, 0);
        input.active(true);
        await clock.measurements
            .firstWhere((wake) => wake.advanced)
            .timeout(const Duration(seconds: 5));
        expect(fixture.simulation.session.tick, greaterThan(tick));
        await fixture.engine.dispose();
        final stopped = fixture.simulation.session.tick;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(fixture.simulation.session.tick, stopped);
        expect(input._listeners, isEmpty);
        expect(clock.isClosed, isTrue);
      } finally {
        await fixture.close();
      }
    },
  );
}
