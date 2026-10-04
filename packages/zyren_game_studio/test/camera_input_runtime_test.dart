import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'authored_runtime_fixture.dart';

void main() {
  test(
    'default exported look axes use the canonical absolute radians',
    () async {
      final f = await start(), play = f.play;
      try {
        play.actions!.setAxis(
          deviceId: 'fixture',
          action: 'look.yaw',
          value: 1,
        );
        play.actions!.setAxis(
          deviceId: 'fixture',
          action: 'look.pitch',
          value: .5,
        );
        advance(play, 1);
        final camera = play.levelRuntime!.camera;
        final forward = (camera.target - camera.position).normalized();
        expect(forward.x.abs(), lessThan(1e-6));
        final pitch = play.actions!.axis('look.pitch') * math.pi / 2;
        expect(forward.z, closeTo(-math.cos(pitch), 1e-6));
        expect(forward.y, closeTo(math.sin(pitch), 1e-6));
        final before = (camera.target - camera.position).normalized();
        advance(play, 1);
        expect(
          (camera.target - camera.position).normalized(),
          before,
          reason: 'Look axes are absolute, not accumulated rotation.',
        );
      } finally {
        await play.stop();
        play.dispose();
      }
    },
  );
}
